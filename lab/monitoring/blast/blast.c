/* blast.c — high-rate frame generator via AF_PACKET on a veth peer.
 * Sends UDP 10.11.12.13:45678 -> 10.0.0.1:80 (the GLB VIP) with a valid
 * IPv4 header checksum, so the director (eth_pcap0 rx_iface=glbt_dpdk)
 * captures + classifies + encapsulates it. Run flat-out (unthrottled) to
 * find the sender ceiling; pin to one core via arg 3.
 *
 * usage: blast <ifname> <seconds> <cpu> <udp_payload_bytes>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <net/if_arp.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <net/if.h>
#include <sys/socket.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <arpa/inet.h>
#include <sched.h>
#include <time.h>

static unsigned short csum(const unsigned char *b, int n) {
    unsigned long s = 0;
    for (int i = 0; i + 1 < n; i += 2) s += ((unsigned)b[i] << 8) | b[i + 1];
    if (n & 1) s += (unsigned)b[n - 1] << 8;
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (unsigned short)(~s & 0xffff);
}

int main(int argc, char **argv) {
    const char *ifname = argc > 1 ? argv[1] : "glbt_py";
    int secs = argc > 2 ? atoi(argv[2]) : 30;
    int cpu  = argc > 3 ? atoi(argv[3]) : 1;
    int plen = argc > 4 ? atoi(argv[4]) : 46;
    cpu %= 64;
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(cpu, &cs);
    sched_setaffinity(0, sizeof cs, &cs);

    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_IP));
    if (fd < 0) { perror("socket"); return 1; }
    int ifi = if_nametoindex(ifname);
    if (!ifi) { perror("if_nametoindex"); return 1; }
    struct ifreq ifr; memset(&ifr, 0, sizeof ifr);
    ifr.ifr_addr.sa_family = ARPHRD_ETHER;
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, &ifr, sizeof ifr) < 0) {
        perror("SO_BINDTODEVICE"); return 1;
    }
    struct sockaddr_ll ll; memset(&ll, 0, sizeof ll);
    ll.sll_family = AF_PACKET; ll.sll_protocol = htons(ETH_P_IP);
    ll.sll_ifindex = ifi; ll.sll_halen = 6;
    unsigned char dmac[6] = {0x4a,0x16,0x02,0xaf,0x03,0xc6}; /* glbt_dpdk */
    memcpy(ll.sll_addr, dmac, 6);

    int ethlen = 14, iplen = 20, tcplen = 20;
    int tot = ethlen + iplen + tcplen + plen;
    unsigned char *f = malloc(tot); memset(f, 0, tot);
    memcpy(f, dmac, 6);
    unsigned char smac[6] = {0x02,0x00,0x00,0x00,0x00,0x01};
    memcpy(f + 6, smac, 6);
    f[12] = 0x08; f[13] = 0x00;
    unsigned char *ip = f + ethlen;
    int iplen_total = iplen + tcplen + plen;
    ip[0] = 0x45; ip[1] = 0;
    ip[2] = (iplen_total >> 8) & 0xff; ip[3] = iplen_total & 0xff;
    ip[4] = 0; ip[5] = 0; ip[6] = 0x40; ip[7] = 0; ip[8] = 64; ip[9] = 6; /* TCP */
    inet_pton(AF_INET, "10.11.12.13", ip + 12);
    inet_pton(AF_INET, "10.0.0.1", ip + 16);
    unsigned short ips = csum(ip, iplen);
    ip[10] = ips >> 8; ip[11] = ips & 0xff;
    unsigned char *tcp = f + ethlen + iplen;
    tcp[0] = 0xb2; tcp[1] = 0x6e;                 /* sport 45678 */
    tcp[2] = 0x00; tcp[3] = 0x50;                 /* dport 80 */
    tcp[4] = 0; tcp[5] = 0; tcp[6] = 0; tcp[7] = 0;   /* seq */
    tcp[8] = 0; tcp[9] = 0; tcp[10] = 0; tcp[11] = 0; /* ack */
    tcp[12] = 0x50; tcp[13] = 0x02;               /* doff=5, flags=SYN */
    tcp[14] = 0xff; tcp[15] = 0xff;               /* window */
    tcp[16] = 0; tcp[17] = 0;                     /* checksum */
    tcp[18] = 0; tcp[19] = 0;                     /* urgent */
    memset(f + ethlen + iplen + tcplen, 0xAB, plen); /* payload (before csum) */
    { /* TCP checksum over pseudo-header + tcp + payload */
        unsigned long s = 0;
        const unsigned char *src = ip + 12, *dst = ip + 16;
        int i;
        for (i = 0; i < 4; i++) s += (src[i] << 8) | dst[i];
        s += 6;
        s += ((tcplen + plen) >> 8) & 0xff;
        s += (tcplen + plen) & 0xff;
        for (i = 0; i < tcplen + plen; i += 2) s += (tcp[i] << 8) | tcp[i + 1];
        while (s >> 16) s = (s & 0xffff) + (s >> 16);
        unsigned short tc = (unsigned short)(~s & 0xffff);
        tcp[16] = tc >> 8; tcp[17] = tc & 0xff;
    }

    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    long sent = 0;
    long stop_ns = (long)secs * 1000000000L;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long el = (t1.tv_sec - t0.tv_sec) * 1000000000L + (t1.tv_nsec - t0.tv_nsec);
        if (el >= stop_ns) break;
        if (sendto(fd, f, tot, 0, (struct sockaddr *)&ll, sizeof ll) < 0) { perror("sendto"); break; }
        sent++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("if=%s cpu=%d pkt_bytes=%d sent=%ld dt=%.3f pps=%.0f Mbps=%.1f\n",
           ifname, cpu, tot, sent, dt, (double)sent / dt, (double)sent * tot * 8 / dt / 1e6);
    close(fd);
    return 0;
}
