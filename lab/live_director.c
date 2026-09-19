/*
 * lab/live_director.c
 *
 * A minimal "live" GLB Director for the lab topology (see lab/setup_topology.sh).
 *
 * It performs exactly the same per-packet work as the production DPDK director
 * for packets that match a bind:
 *
 *   1. classify the packet against the forwarding table binds
 *   2. glb_calculate_packet_route()  (siphash of the flow -> table row ->
 *                                     primary/secondary pair)          [glb_encap.c]
 *   3. glb_encapsulate_packet()      (build Eth + IPv4 + UDP + GUE(GLB)
 *                                     headers, insert secondary hop)    [glb_encap.c]
 *   4. compute the outer IP/UDP checksums (software, same as the DPDK
 *      director with offloads disabled, see glb_checksum_offloading())
 *   5. transmit the GUE frame
 *
 * What is different from the production director (lab-only shortcuts):
 *   - single threaded: no lcores / rte_distributor / worker split
 *   - RX is an AF_PACKET socket bound to a veth (the production director owns
 *     a NIC via DPDK; this binary is what the repo's "PCAP_MODE" targets hint at)
 *   - bind classification is a linear scan (production uses rte_acl, see
 *     src/glb-director/bind_classifier.c)
 *   - non-matching packets are dropped (production sends them to KNI so Linux
 *     can keep serving the host, see src/glb-director/glb_kni.c)
 *
 * Signals (mirroring the production director where applicable):
 *   - SIGUSR1 : reload the forwarding table  (== `systemctl reload glb-director`)
 *   - SIGUSR2 : dump counters to the -s stats file (lab addition)
 *   - SIGINT/SIGTERM : exit
 *
 * Build: see lab/build.sh
 *
 * BSD 3-Clause License, Copyright (c) 2026 (lab code). The linked
 * src/glb-director/*.c files carry the upstream license headers.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <getopt.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

/* DPDK headers are used header-only (struct types, RTE_MAX_LCORE). */
#include <rte_ether.h>
#include <rte_lcore.h>

#include "config.h"
#include "glb_director_config.h"
#include "glb_encap.h"
#include "glb_fwd_config.h"
#include "log.h"

#define MAX_PKT 9216

/* A contiguous packet wrapper that plays the role of DPDK's rte_mbuf for the
 * shared encapsulation code (same trick as src/glb-director/glb_encap_pcap.c).
 */
struct lab_packet {
	uint8_t *data;
	uint32_t len;
};

/* Hook the shared packet parser uses to read packet bytes
 * (GLB_PACKET_PARSING_LINEARISER mode, see glb-hashing/packet_parsing.h).
 * Our packets are always contiguous, so no linearisation is needed.
 */
const void *encap_packet_data_read(void *packet_data, uint32_t off, uint32_t len,
				   void *buf)
{
	struct lab_packet *pkt = (struct lab_packet *)packet_data;
	(void)buf;
	if (pkt->len < off + len)
		return NULL;
	return &pkt->data[off];
}

/* ------------------------------------------------------------------ */
/* Software checksums. The DPDK director computes exactly these when   */
/* hardware offloading is disabled (glb_checksum_offloading() in       */
/* src/glb-director/glb_encap_dpdk.c).                                 */
/* ------------------------------------------------------------------ */

static uint32_t csum16(const void *data, size_t len, uint32_t sum)
{
	const uint8_t *p = (const uint8_t *)data;
	while (len >= 2) {
		sum += (uint32_t)((p[0] << 8) | p[1]);
		p += 2;
		len -= 2;
	}
	if (len)
		sum += (uint32_t)(p[0] << 8); /* zero-extend the odd byte */
	return sum;
}

static uint16_t csum_finish(uint32_t sum)
{
	while (sum >> 16)
		sum = (sum & 0xffff) + (sum >> 16);
	return (uint16_t)sum;
}

static void fixup_outer_checksums(struct pdnet_ipv4_hdr *ip,
				  struct pdnet_udp_hdr *udp)
{
	ip->checksum = 0;
	ip->checksum = htons(csum_finish(csum16(ip, sizeof(*ip), 0)));

	/* UDP checksum over the IPv4 pseudo-header + UDP segment */
	struct {
		uint32_t saddr;
		uint32_t daddr;
		uint8_t zero;
		uint8_t proto;
		uint16_t ulen;
	} __attribute__((packed)) pseudo = {
	    ip->src_addr, ip->dst_addr, 0, PDNET_IP_PROTO_UDP, udp->length};

	udp->checksum = 0;
	uint32_t s = csum16(&pseudo, sizeof(pseudo), 0);
	s = csum16(udp, ntohs(udp->length), s);
	uint16_t c = csum_finish(s);
	/* a computed UDP checksum of 0 is transmitted as 0xffff */
	udp->checksum = (c == 0) ? htons(0xffff) : htons(c);
}

/* ------------------------------------------------------------------ */
/* Bind classification. Production uses an rte_acl classifier          */
/* (bind_classifier.c); this is the simple linear-scan equivalent.    */
/* ------------------------------------------------------------------ */

static int classify_packet(struct glb_fwd_config_ctx *ctx, const uint8_t *pkt,
			   uint32_t len)
{
	const struct pdnet_ethernet_hdr *eth;
	const struct pdnet_ipv4_hdr *ip;
	uint8_t proto;
	uint16_t l4_total;
	uint16_t dport = 0;

	if (len < sizeof(struct pdnet_ethernet_hdr) + sizeof(struct pdnet_ipv4_hdr))
		return -1;

	eth = (const struct pdnet_ethernet_hdr *)pkt;
	if (ntohs(eth->ether_type) != PDNET_ETHER_TYPE_IPV4)
		return -1;

	ip = (const struct pdnet_ipv4_hdr *)(pkt + sizeof(struct pdnet_ethernet_hdr));
	if (ip->version != PDNET_IPV4_VERSION)
		return -1;

	l4_total = ntohs(ip->total_length);
	if (l4_total < sizeof(struct pdnet_ipv4_hdr))
		return -1;

	proto = ip->next_proto;

	if (proto == PDNET_IP_PROTO_TCP || proto == PDNET_IP_PROTO_UDP) {
		if (l4_total < sizeof(struct pdnet_ipv4_hdr) +
				  sizeof(struct pdnet_l4_ports_hdr))
			return -1;
		const struct pdnet_l4_ports_hdr *l4 =
		    (const struct pdnet_l4_ports_hdr *)((const uint8_t *)ip +
					sizeof(struct pdnet_ipv4_hdr));
		dport = l4->dst_port;
	}

	uint32_t t, b;
	for (t = 0; t < ctx->raw_config->num_tables; t++) {
		struct glb_fwd_config_content_table *table = &ctx->raw_config->tables[t];
		for (b = 0; b < table->num_binds; b++) {
			struct glb_fwd_config_content_table_bind *bind = &table->binds[b];

			if (bind->family != FAMILY_IPV4)
				continue;
			if (bind->proto != proto)
				continue;

			uint16_t bits = bind->ip_bits > 32 ? 32 : bind->ip_bits;
			uint32_t mask = bits ? htonl(0xffffffffu << (32 - bits)) : 0;
			if ((ip->dst_addr & mask) != (bind->ipv4_addr & mask))
				continue;

			/* bind ports are stored in host byte order (see cli/main.c) */
			if (dport < bind->port_start || dport > bind->port_end)
				continue;

			return (int)t;
		}
	}

	return -1;
}

/* ------------------------------------------------------------------ */
/* Counters / signals                                                  */
/* ------------------------------------------------------------------ */

struct lab_counters {
	uint64_t total_packets;
	uint64_t matched_packets;
	uint64_t encap_successes;
	uint64_t encap_failures;
	uint64_t dropped_packets;
	uint64_t reloads;
};

static struct lab_counters stats;
static volatile sig_atomic_t reload_requested = 0;
static volatile sig_atomic_t stats_requested = 0;
static volatile sig_atomic_t stop_requested = 0;
static char stats_file[256] = "";

static void dump_stats(void)
{
	glb_log_info(
	    "[stats] total=%llu matched=%llu encap_ok=%llu encap_fail=%llu "
	    "dropped=%llu reloads=%llu",
	    (unsigned long long)stats.total_packets,
	    (unsigned long long)stats.matched_packets,
	    (unsigned long long)stats.encap_successes,
	    (unsigned long long)stats.encap_failures,
	    (unsigned long long)stats.dropped_packets,
	    (unsigned long long)stats.reloads);

	if (stats_file[0] != '\0') {
		FILE *f = fopen(stats_file, "w");
		if (f == NULL)
			return;
		fprintf(f, "total_packets: %llu\n",
			(unsigned long long)stats.total_packets);
		fprintf(f, "matched_packets: %llu\n",
			(unsigned long long)stats.matched_packets);
		fprintf(f, "encap_successes: %llu\n",
			(unsigned long long)stats.encap_successes);
		fprintf(f, "encap_failures: %llu\n",
			(unsigned long long)stats.encap_failures);
		fprintf(f, "dropped_packets: %llu\n",
			(unsigned long long)stats.dropped_packets);
		fprintf(f, "reloads: %llu\n", (unsigned long long)stats.reloads);
		fclose(f);
	}
}

static void on_signal(int signum)
{
	if (signum == SIGUSR1)
		reload_requested = 1;
	else if (signum == SIGUSR2)
		stats_requested = 1;
	else
		stop_requested = 1;
}

static void reload_config(struct glb_fwd_config_ctx **ctx)
{
	/* NB: create_glb_fwd_config() exits the process on an invalid table
	 * file, matching the behaviour of the production director's initial
	 * load. Signal a bad file and the lab director dies - by design. */
	struct glb_fwd_config_ctx *new_ctx =
	    create_glb_fwd_config(g_director_config->forwarding_table_path);
	stats.reloads++;
	glb_log_info("reloaded forwarding table");
	glb_fwd_config_ctx_decref(*ctx);
	*ctx = new_ctx;
}

static int get_iface_mac(const char *ifname, struct ether_addr *out)
{
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		return -1;

	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

	if (ioctl(fd, SIOCGIFHWADDR, &ifr) != 0) {
		close(fd);
		return -1;
	}

	memcpy(out, ifr.ifr_hwaddr.sa_data, 6);
	close(fd);
	return 0;
}

/* ------------------------------------------------------------------ */

int main(int argc, char **argv)
{
	char config_file[256] = "";
	char forwarding_table[256] = "";
	char iface[IFNAMSIZ] = "";
	int opt;

	static struct option long_options[] = {
	    {"config-file", required_argument, NULL, 'c'},
	    {"forwarding-table", required_argument, NULL, 't'},
	    {"interface", required_argument, NULL, 'i'},
	    {"stats-file", required_argument, NULL, 's'},
	    {"debug", no_argument, NULL, 'v'},
	    {NULL, 0, NULL, 0}};

	while ((opt = getopt_long(argc, argv, ":c:t:i:s:v", long_options,
				  NULL)) != -1) {
		switch (opt) {
		case 'c':
			strcpy(config_file, optarg);
			break;
		case 't':
			strcpy(forwarding_table, optarg);
			break;
		case 'i':
			strncpy(iface, optarg, IFNAMSIZ - 1);
			break;
		case 's':
			strncpy(stats_file, optarg, sizeof(stats_file) - 1);
			break;
		case 'v':
			debug = true;
			break;
		default:
			fprintf(stderr,
				"usage: live_director -c <director.conf> "
				"-t <forwarding_table.bin> -i <iface> "
				"[-s <stats-file>] [-v]\n");
			return 1;
		}
	}

	if (config_file[0] == '\0' || forwarding_table[0] == '\0' ||
	    iface[0] == '\0') {
		fprintf(stderr,
			"usage: live_director -c <director.conf> "
			"-t <forwarding_table.bin> -i <iface> "
			"[-s <stats-file>] [-v]\n");
		return 1;
	}

	signal(SIGUSR1, on_signal);
	signal(SIGUSR2, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGTERM, on_signal);

	glb_log_info("loading GLB configuration");
	g_director_config =
	    glb_director_config_load_file(config_file, forwarding_table);
	if (g_director_config == NULL) {
		glb_log_error_and_exit("failed to load director config");
	}

	/* The production director learns local_ether_addr from the DPDK
	 * port; here we take it from the interface we're bound to. */
	if (get_iface_mac(iface, &g_director_config->local_ether_addr) != 0) {
		glb_log_error_and_exit("could not read MAC of %s", iface);
	}

	struct glb_fwd_config_ctx *ctx =
	    create_glb_fwd_config(g_director_config->forwarding_table_path);
	glb_fwd_config_dump(ctx);

	char mac[32];
	ether_format_addr(mac, sizeof(mac), &g_director_config->gateway_ether_addr);
	{
		char ip[INET_ADDRSTRLEN];
		inet_ntop(AF_INET, &g_director_config->local_ip_addr, ip,
			  sizeof(ip));
		glb_log_info("lab director: out mac=%s out src ip=%s iface=%s",
			     mac, ip, iface);
		glb_log_info(
		    "lab director: hash fields src_addr=%d dst_addr=%d "
		    "src_port=%d dst_port=%d",
		    g_director_config->hash_fields.src_addr,
		    g_director_config->hash_fields.dst_addr,
		    g_director_config->hash_fields.src_port,
		    g_director_config->hash_fields.dst_port);
	}

	/* AF_PACKET raw socket, bound to the interface (like the repo's
	 * stub_server.c), promisc so we also see frames that the local stack
	 * would drop. */
	int sock = socket(PF_PACKET, SOCK_RAW, htons(ETH_P_IP));
	if (sock < 0) {
		glb_log_error_and_exit("socket(PF_PACKET): %s", strerror(errno));
	}

	struct ifreq ifr;
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);

	if (ioctl(sock, SIOCGIFFLAGS, &ifr) != 0) {
		glb_log_error_and_exit("SIOCGIFFLAGS %s: %s", iface,
				       strerror(errno));
	}
	ifr.ifr_flags |= IFF_UP | IFF_RUNNING | IFF_PROMISC;
	if (ioctl(sock, SIOCSIFFLAGS, &ifr) != 0) {
		glb_log_error("SIOCSIFFLAGS %s: %s (continuing without promisc)",
			      iface, strerror(errno));
	}
	if (setsockopt(sock, SOL_SOCKET, SO_BINDTODEVICE, iface,
		       strlen(iface) + 1) != 0) {
		glb_log_error_and_exit("SO_BINDTODEVICE %s: %s", iface,
				       strerror(errno));
	}

	glb_log_info("lab director listening on %s (ready)", iface);

	uint8_t pkt_buf[MAX_PKT];
	uint8_t *out_buf = NULL;
	size_t out_cap = 0;

	while (!stop_requested) {
		if (reload_requested) {
			reload_requested = 0;
			reload_config(&ctx);
		}
		if (stats_requested) {
			stats_requested = 0;
			dump_stats();
		}

		ssize_t n = recvfrom(sock, pkt_buf, sizeof(pkt_buf), 0, NULL,
				     NULL);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			glb_log_error_and_exit("recvfrom: %s", strerror(errno));
		}
		stats.total_packets++;

		int table = classify_packet(ctx, pkt_buf, (uint32_t)n);
		if (table < 0) {
			stats.dropped_packets++;
			continue;
		}

		/* classify_packet() guarantees these sizes */
		const struct pdnet_ethernet_hdr *eth =
		    (const struct pdnet_ethernet_hdr *)pkt_buf;
		const struct pdnet_ipv4_hdr *ip =
		    (const struct pdnet_ipv4_hdr *)(pkt_buf +
				sizeof(struct pdnet_ethernet_hdr));

		/* log connection lifecycle events at info level */
		if (ip->next_proto == PDNET_IP_PROTO_TCP &&
		    n >= sizeof(struct pdnet_ethernet_hdr) +
			    sizeof(struct pdnet_ipv4_hdr) + 14) {
			const uint8_t *tcp = pkt_buf +
			    sizeof(struct pdnet_ethernet_hdr) +
			    sizeof(struct pdnet_ipv4_hdr);
			uint8_t flags = tcp[13];
			if ((flags & 0x02) && !(flags & 0x10)) {
				struct in_addr sa, da;
				sa.s_addr = ip->src_addr;
				da.s_addr = ip->dst_addr;
				glb_log_info(
				    "[flow] SYN %s -> %s:%u (table %d)",
				    inet_ntoa(sa), inet_ntoa(da),
				    ntohs(((const struct pdnet_l4_ports_hdr *)(tcp))->dst_port),
				    table);
			}
		}

		/* the shared route calculation (siphash -> table row ->
		 * primary/secondary), exactly as the DPDK director does it */
		struct lab_packet pkt;
		pkt.data = pkt_buf;
		pkt.len = (uint32_t)n;

		glb_route_context rctx;
		memset(&rctx, 0, sizeof(rctx));

		if (glb_calculate_packet_route(ctx, (unsigned)table, &pkt,
					       &rctx) != 0) {
			stats.encap_failures++;
			glb_log_info("route calculation failed, dropping");
			continue;
		}

		uint32_t inner_len = n - sizeof(struct pdnet_ethernet_hdr);
		uint32_t encap_size = ROUTE_CONTEXT_ENCAP_SIZE(&rctx);

		if (out_cap < encap_size + inner_len) {
			free(out_buf);
			out_cap = encap_size + inner_len + 512;
			out_buf = malloc(out_cap);
			if (out_buf == NULL) {
				stats.encap_failures++;
				continue;
			}
		}

		/* drop the original ethernet header, make room for the new
		 * encap headers (mirrors rte_pktmbuf_adj + rte_pktmbuf_prepend) */
		memcpy(out_buf + encap_size,
		       pkt_buf + sizeof(struct pdnet_ethernet_hdr), inner_len);

		/* the real GLB encapsulation (outer eth/ip/udp/gue headers,
		 * secondary hop in the GUE private data) */
		if (glb_encapsulate_packet((struct ether_hdr *)out_buf,
					   &rctx) != 0) {
			stats.encap_failures++;
			glb_log_info("encapsulation failed, dropping");
			continue;
		}

		fixup_outer_checksums((struct pdnet_ipv4_hdr *)(out_buf +
						    sizeof(struct ether_hdr)),
				      (struct pdnet_udp_hdr *)(out_buf +
						  sizeof(struct ether_hdr) +
						  sizeof(struct pdnet_ipv4_hdr)));

		stats.matched_packets++;

		if (sendto(sock, out_buf, encap_size + inner_len, 0, NULL, 0)
		    != (ssize_t)(encap_size + inner_len)) {
			stats.encap_failures++;
			glb_log_info("sendto failed: %s", strerror(errno));
			continue;
		}

		stats.encap_successes++;
	}

	ifr.ifr_flags &= ~IFF_PROMISC;
	ioctl(sock, SIOCSIFFLAGS, &ifr);
	close(sock);
	dump_stats();
	glb_log_info("lab director stopped");
	return 0;
}
