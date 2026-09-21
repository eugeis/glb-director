/* blast_route.c — high-rate TCP blaster via SOCK_RAW to 10.0.0.1:80 (the GLB VIP).
 *
 * For the cross-host end-to-end test: this runs on the CLIENT box (406x) and pushes
 * packets toward 405x's director over the real network. It relies on a route
 *
 *     ip route add 10.0.0.1/32 via <405x-ip> dev <nic>
 *
 * on this box so the kernel routes the packets to 405x (L2/ARP handled by the kernel
 * — no manual MAC juggling). Source IP is this box's real IP (arg 3) to avoid uRPF
 * drops on the data network; the director's bind classifier is source-agnostic (it
 * matches dst VIP:port + proto), so the real src IP still matches + encaps.
 *
 * The L3 flow is TCP 45678 -> 10.0.0.1:80 (SYN) — the bind rule is proto 6 (TCP);
 * sending UDP would classify as unclassified and be dropped (see README).
 *
 * Build:  gcc -O2 -o blast_route blast_route.c
 * usage:  blast_route <secs> <cpu> <src_ip> <tcp_payload_bytes>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
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
    int secs = argc > 1 ? atoi(argv[1]) : 15;
    int cpu = argc > 2 ? atoi(argv[2]) : 1;
    const char *srcip = argc > 3 ? argv[3] : "10.10.116.118";
    int plen = argc > 4 ? atoi(argv[4]) : 60;
    cpu %= 64;
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(cpu, &cs);
    sched_setaffinity(0, sizeof cs, &cs);

    int fd = socket(AF_INET, SOCK_RAW, IPPROTO_TCP);
    if (fd < 0) { perror("socket"); return 1; }

    struct sockaddr_in dst; memset(&dst, 0, sizeof dst);
    dst.sin_family = AF_INET;
    inet_pton(AF_INET, "10.0.0.1", &dst.sin_addr);
    dst.sin_port = htons(80);

    int tcplen = 20, iplen = 20;
    int iplen_total = tcplen + plen;
    int tot = iplen + iplen_total;
    unsigned char *p = malloc(tot); memset(p, 0, tot);

    /* IPv4 header */
    p[0] = 0x45; p[1] = 0;
    p[2] = (iplen_total >> 8) & 0xff; p[3] = iplen_total & 0xff;
    p[4] = 0; p[5] = 0; p[6] = 0x40; p[7] = 0;   /* id=0, DF */
    p[8] = 64; p[9] = 6;                          /* ttl, proto=TCP */
    inet_pton(AF_INET, srcip, p + 12);
    inet_pton(AF_INET, "10.0.0.1", p + 16);
    unsigned short ips = csum(p, iplen);
    p[10] = ips >> 8; p[11] = ips & 0xff;

    /* TCP header */
    unsigned char *t = p + iplen;
    t[0] = 0xb2; t[1] = 0x6e;                 /* sport 45678 */
    t[2] = 0x00; t[3] = 0x50;                 /* dport 80 */
    t[4] = t[5] = t[6] = t[7] = 0;            /* seq */
    t[8] = t[9] = t[10] = t[11] = 0;          /* ack */
    t[12] = 0x50; t[13] = 0x02;               /* doff=5, flags=SYN */
    t[14] = 0xff; t[15] = 0xff;               /* window */
    t[16] = t[17] = 0;                         /* checksum */
    t[18] = t[19] = 0;                         /* urgent */
    memset(p + iplen + tcplen, 0xAB, plen);    /* payload (before csum) */

    /* TCP checksum over pseudo-header + tcp + payload */
    {
        unsigned long s = 0;
        int i;
        for (i = 0; i < 4; i++) s += ((unsigned)(p + 12)[i] << 8) | (unsigned)(p + 16)[i];
        s += 6;
        s += ((tcplen + plen) >> 8) & 0xff;
        s += (tcplen + plen) & 0xff;
        for (i = 0; i < tcplen + plen; i += 2) s += ((unsigned)t[i] << 8) | (unsigned)t[i + 1];
        while (s >> 16) s = (s & 0xffff) + (s >> 16);
        unsigned short tc = (unsigned short)(~s & 0xffff);
        t[16] = tc >> 8; t[17] = tc & 0xff;
    }

    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    long sent = 0;
    long stop_ns = (long)secs * 1000000000L;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long el = (t1.tv_sec - t0.tv_sec) * 1000000000L + (t1.tv_nsec - t0.tv_nsec);
        if (el >= stop_ns) break;
        if (sendto(fd, p, tot, 0, (struct sockaddr *)&dst, sizeof dst) < 0) { perror("sendto"); break; }
        sent++;
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double dt = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("route blaster src=%s sent=%ld dt=%.3f pps=%.0f Mbps=%.1f\n",
           srcip, sent, dt, (double)sent / dt, (double)sent * tot * 8 / dt / 1e6);
    close(fd);
    return 0;
}
