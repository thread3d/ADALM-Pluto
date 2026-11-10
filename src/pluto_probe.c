/*
 * pluto_probe - a standalone ADALM-PLUTO receive checker, independent of ogn-rf.
 *
 * Why this exists: when ogn-rf will not receive, the question is always "is the radio or is the
 * receiver at fault?". This program answers the first half without dragging the second half in. It
 * opens the device through libiio, reports what the device says about itself, tunes, captures, and
 * prints statistics that say whether real RF came out (a noise floor with a normal crest factor) or
 * something is wrong (all zeros, a stuck bit, clipping, a DC offset).
 *
 * It is the ADALM-PLUTO counterpart of rspduo_probe.c in the RSPduo repository, and it deliberately
 * has the same job and the same shape.
 *
 * Build:   gcc -O2 -Wall -o pluto_probe pluto_probe.c -liio -lm
 * Or let the wrapper do it:  ../scripts/probe-pluto.sh --capture
 *
 * Usage:
 *   ./pluto_probe                      list the contexts libiio can see, then stop
 *   ./pluto_probe -u usb:1.4.4.3       use a specific context (also ip:192.168.2.1, local:)
 *   ./pluto_probe -u ip:192.168.2.1 -f 868200000 -r 4000000 -g 40 -n 2000000
 *   ./pluto_probe -o 868.u8            also write unsigned 8-bit interleaved I/Q (spectrum.py food)
 *
 * Options:
 *   -u URI    libiio context URI. Default: the first usb: or ip: context that scans, else "usb:".
 *   -f HZ     receive frequency, default 868400000 (the upper of the two European OGN channels)
 *   -r HZ     sample rate to request from the AD9363, default 4000000 (see docs/hardware.md: the
 *             chip cannot go below ~2.08 MSPS, so ogn-rf's 1.0/2.048 MSPS are decimated to, not
 *             requested)
 *   -g DB     hardware gain in dB, or "auto" for the chip's own gain control. Default: leave alone.
 *   -n N      samples to capture, default 2000000 (about half a second at 4 MSPS)
 *   -o FILE   write the capture as unsigned 8-bit interleaved I/Q, the format ogn-rf's DSP expects
 *   -s SHIFT  right-shift applied when converting to 8-bit, default 4 (12 bits -> 8, provisional)
 *   -b HZ     RF bandwidth to request, default 0 = leave the driver's value
 *   -v        verbose: print every channel and attribute the device exposes
 *
 * Exit status: 0 = capture looked healthy, 1 = failure, 2 = usage.
 *
 * Copyright (c) 2026 The OGN Project. GPLv3, matching ogn-rf.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <errno.h>
#include <unistd.h>
#include <iio.h>

#ifndef VERSION
#define VERSION "0.1"
#endif

static int verbosity = 0;

/* libiio 0.19 reports its own version through out-parameters rather than returning a string, so
 * wrap that once here instead of repeating three arguments at every call site. (Newer libiio
 * returns a const char *; if this is ever built against one, this is the only function to change.) */
static const char *libiio_version(void)
{
    static char ver[48];
    if (ver[0]) return ver;
    unsigned int maj = 0, min = 0;
    char git[8] = "";
    iio_library_get_version(&maj, &min, git);
    git[sizeof(git) - 1] = 0;
    if (git[0]) snprintf(ver, sizeof(ver), "%u.%u (git %s)", maj, min, git);
    else        snprintf(ver, sizeof(ver), "%u.%u", maj, min);
    return ver;
}

/* ---------------------------------------------------------------------------------------------- */
/* small helpers                                                                                   */
/* ---------------------------------------------------------------------------------------------- */

static const char *opt(int argc, char **argv, int *i)
{
    if (*i + 1 >= argc) { fprintf(stderr, "option %s needs a value\n", argv[*i]); exit(2); }
    return argv[++*i];
}

/* Read an attribute as a long long; returns 0 on success and leaves *val untouched on failure. */
static int read_ll(struct iio_channel *ch, struct iio_device *dev, const char *name, long long *val)
{
    char buf[128];
    ssize_t n = -1;
    if (ch)  n = iio_channel_attr_read(ch, name, buf, sizeof(buf));
    else     n = iio_device_attr_read(dev, name, buf, sizeof(buf));
    if (n < 0) return -1;
    buf[n] = 0;
    errno = 0;
    char *end = NULL;
    long long v = strtoll(buf, &end, 10);
    if (errno || end == buf) return -1;
    *val = v;
    return 0;
}

static void print_attr(struct iio_channel *ch, struct iio_device *dev, const char *name, const char *label)
{
    char buf[256];
    ssize_t n = ch ? iio_channel_attr_read(ch, name, buf, sizeof(buf))
                   : iio_device_attr_read(dev, name, buf, sizeof(buf));
    if (n <= 0) return;
    buf[n] = 0;
    /* available lists contain newlines; keep them readable on one line */
    for (char *p = buf; *p; p++) if (*p == '\n') *p = ' ';
    printf("    %-34s = %s\n", label, buf);
}

/* ---------------------------------------------------------------------------------------------- */
/* discovery                                                                                       */
/* ---------------------------------------------------------------------------------------------- */

static void list_contexts(void)
{
    struct iio_scan_context *sc = iio_create_scan_context(NULL, 0);
    if (!sc) { printf("libiio %s: cannot create a scan context\n", libiio_version()); return; }

    struct iio_context_info **info = NULL;
    ssize_t n = iio_scan_context_get_info_list(sc, &info);
    if (n <= 0) {
        printf("libiio %s scans nothing. Either no device is present, no udev rule grants access,\n"
               "or the device is sitting in mass-storage mode rather than exposing IIO.\n",
               libiio_version());
    } else {
        printf("libiio %s sees %zd context(s) (\"available contexts\"):\n", libiio_version(), n);
        for (ssize_t i = 0; i < n; i++)
            printf("  [%zd] %-24s %s\n", i,
                   iio_context_info_get_uri(info[i]),
                   iio_context_info_get_description(info[i]));
        printf("\nUse one of these with -u. A Pluto over USB shows up as usb:<bus>.<port chain>.\n");
    }
    if (info) iio_context_info_list_free(info);
    iio_scan_context_destroy(sc);
}

/* Scan for a context that could be a radio: usb: first, then ip:. Returns a malloc'd URI, or NULL.
 *
 * This is the only honest health test for a Pluto over USB. The kernel creates no iio:device for
 * it - the IIO protocol runs over libusb in user space - so /sys/bus/iio/devices stays empty even
 * when the radio is perfectly healthy, and a check that looks there is checking the wrong thing.
 *
 * Note what a NULL result does and does not mean: libiio's scan only reports contexts it can
 * actually open, so an unreadable USB node (no udev rule) and an absent device produce the same
 * empty list. Distinguishing them is the caller's job, which is why probe-pluto.sh looks at the
 * node permissions separately. */
static char *scan_for_context(int show_list)
{
    char *found = NULL;
    struct iio_scan_context *sc = iio_create_scan_context(NULL, 0);
    struct iio_context_info **info = NULL;
    ssize_t n = sc ? iio_scan_context_get_info_list(sc, &info) : -1;

    if (n > 0) {
        for (ssize_t k = 0; k < n && !found; k++)
            if (!strncmp(iio_context_info_get_uri(info[k]), "usb:", 4))
                found = strdup(iio_context_info_get_uri(info[k]));
        for (ssize_t k = 0; k < n && !found; k++)
            if (!strncmp(iio_context_info_get_uri(info[k]), "ip:", 3))
                found = strdup(iio_context_info_get_uri(info[k]));
        if (show_list) {
            printf("libiio %s sees %zd context(s):\n", libiio_version(), n);
            for (ssize_t k = 0; k < n; k++)
                printf("  %-24s %s\n", iio_context_info_get_uri(info[k]),
                       iio_context_info_get_description(info[k]));
        }
    }
    if (info) iio_context_info_list_free(info);
    if (sc) iio_scan_context_destroy(sc);
    return found;
}

static void describe_context(struct iio_context *ctx)
{
    unsigned int maj = 0, min = 0;
    char git[8] = "";
    iio_context_get_version(ctx, &maj, &min, git);
    printf("  backend:  %s\n", iio_context_get_name(ctx));
    printf("  version:  %u.%u %s\n", maj, min, git);
    printf("  devices:  %u\n", iio_context_get_devices_count(ctx));

    if (verbosity < 1) {
        for (unsigned int i = 0; i < iio_context_get_devices_count(ctx); i++) {
            struct iio_device *d = iio_context_get_device(ctx, i);
            printf("    %-24s %s\n", iio_device_get_id(d),
                   iio_device_get_name(d) ? iio_device_get_name(d) : "");
        }
        return;
    }

    for (unsigned int i = 0; i < iio_context_get_devices_count(ctx); i++) {
        struct iio_device *d = iio_context_get_device(ctx, i);
        printf("    device %s  name=%s  channels=%u\n",
               iio_device_get_id(d), iio_device_get_name(d) ? iio_device_get_name(d) : "(none)",
               iio_device_get_channels_count(d));
        for (unsigned int c = 0; c < iio_device_get_channels_count(d); c++) {
            struct iio_channel *ch = iio_device_get_channel(d, c);
            const struct iio_data_format *fmt = iio_channel_get_data_format(ch);
            printf("      %-14s %-8s %-8s bits=%u shift=%u\n",
                   iio_channel_get_id(ch),
                   iio_channel_is_output(ch) ? "output" : "input",
                   iio_channel_is_scan_element(ch) ? "scan" : "",
                   fmt ? fmt->bits : 0, fmt ? fmt->shift : 0);
        }
    }
}

/* ---------------------------------------------------------------------------------------------- */
/* the AD9363, as an IIO device                                                                    */
/* ---------------------------------------------------------------------------------------------- */

struct phy
{
    struct iio_device  *dev;      /* ad9361-phy */
    struct iio_device  *rx;       /* cf-ad9361-lpc, the RX DMA */
    struct iio_channel *lo;       /* altvoltage0, the RX local oscillator */
    struct iio_channel *rx0;      /* voltage0, the RX channel carrying rate/gain/bandwidth */
    struct iio_channel *i;        /* scan channel, I */
    struct iio_channel *q;        /* scan channel, Q */
    unsigned int        bits;     /* significant bits per sample */
    unsigned int        shift;    /* driver's declared shift */
    int                 is_signed;
};

static int find_phy(struct iio_context *ctx, struct phy *p)
{
    memset(p, 0, sizeof(*p));
    p->dev = iio_context_find_device(ctx, "ad9361-phy");
    p->rx  = iio_context_find_device(ctx, "cf-ad9361-lpc");
    p->bits = 16;
    p->is_signed = 1;

    if (!p->dev) {
        fprintf(stderr, "no \"ad9361-phy\" device in this context.\n");
        fprintf(stderr, "This does not look like a Pluto exposing its radio over IIO. Devices seen:\n");
        for (unsigned int i = 0; i < iio_context_get_devices_count(ctx); i++)
            fprintf(stderr, "  %s\n", iio_device_get_id(iio_context_get_device(ctx, i)));
        return -1;
    }
    if (!p->rx) {
        fprintf(stderr, "no \"cf-ad9361-lpc\" (RX DMA) device in this context.\n");
        return -1;
    }

    p->lo  = iio_device_find_channel(p->dev, "altvoltage0", true);   /* RX_LO is an output channel */
    p->rx0 = iio_device_find_channel(p->dev, "voltage0", false);
    if (!p->lo)  fprintf(stderr, "warning: altvoltage0 (RX LO) not found; cannot tune\n");
    if (!p->rx0) fprintf(stderr, "warning: voltage0 on the phy not found; cannot set rate or gain\n");

    /* The DMA device's scan channels are the I/Q pairs. voltage0/voltage1 is the first RX channel. */
    p->i = iio_device_find_channel(p->rx, "voltage0", false);
    p->q = iio_device_find_channel(p->rx, "voltage1", false);
    if (!p->i || !p->q) {
        fprintf(stderr, "no voltage0/voltage1 scan channels on cf-ad9361-lpc\n");
        return -1;
    }
    const struct iio_data_format *fmt = iio_channel_get_data_format(p->i);
    if (fmt) { p->bits = fmt->bits; p->shift = fmt->shift; p->is_signed = fmt->is_signed; }
    return 0;
}

static void describe_phy(struct phy *p)
{
    printf("  AD9363, as reported by the device:\n");
    if (p->rx0) {
        print_attr(p->rx0, NULL, "sampling_frequency_available", "rate available");
        print_attr(p->rx0, NULL, "sampling_frequency",           "rate now");
        print_attr(p->rx0, NULL, "rf_bandwidth",                 "bandwidth now");
        print_attr(p->rx0, NULL, "hardwaregain_available",      "gain available");
        print_attr(p->rx0, NULL, "hardwaregain",                 "gain now");
    }
    print_attr(NULL, p->dev, "gain_control_mode",   "gain mode");
    print_attr(NULL, p->dev, "gain_control_mode_available", "gain modes available");
    if (p->lo) print_attr(p->lo, NULL, "frequency",  "LO now");
    printf("  sample format: %u bits, shift %u, %s (this fixes the 8-bit conversion shift)\n",
           p->bits, p->shift, p->is_signed ? "signed" : "unsigned");
}

/* ---------------------------------------------------------------------------------------------- */
/* statistics                                                                                      */
/* ---------------------------------------------------------------------------------------------- */

struct stats
{
    long long n;
    double sum, sumsq;
    double mn, mx;
    long long clipped;
};

static void stats_init(struct stats *s) { memset(s, 0, sizeof(*s)); s->mn = 1e30; s->mx = -1e30; }

static void stats_add(struct stats *s, double v)
{
    s->n++;
    s->sum   += v;
    s->sumsq += v * v;
    if (v < s->mn) s->mn = v;
    if (v > s->mx) s->mx = v;
}

static double stats_mean(const struct stats *s) { return s->n ? s->sum / s->n : 0.0; }
static double stats_rms(const struct stats *s)  { return s->n ? sqrt(s->sumsq / s->n) : 0.0; }

/* ---------------------------------------------------------------------------------------------- */

int main(int argc, char **argv)
{
    const char *uri = NULL;
    uint32_t freq = 868400000;
    uint32_t rate = 4000000;
    long long gain = -1;                 /* -1 = do not touch */
    int gain_auto = 0;
    uint32_t bw = 0;
    long     want = 2000000;
    const char *outpath = NULL;
    int shift = 4;
    int scan_only = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-u")) uri = opt(argc, argv, &i);
        else if (!strcmp(argv[i], "-f")) freq = (uint32_t)strtoul(opt(argc, argv, &i), NULL, 0);
        else if (!strcmp(argv[i], "-r")) rate = (uint32_t)strtoul(opt(argc, argv, &i), NULL, 0);
        else if (!strcmp(argv[i], "-g")) {
            const char *v = opt(argc, argv, &i);
            if (!strcasecmp(v, "auto")) gain_auto = 1; else gain = strtoll(v, NULL, 0);
        }
        else if (!strcmp(argv[i], "-b")) bw = (uint32_t)strtoul(opt(argc, argv, &i), NULL, 0);
        else if (!strcmp(argv[i], "-n")) want = strtol(opt(argc, argv, &i), NULL, 0);
        else if (!strcmp(argv[i], "-o")) outpath = opt(argc, argv, &i);
        else if (!strcmp(argv[i], "-s")) shift = atoi(opt(argc, argv, &i));
        else if (!strcmp(argv[i], "-v")) verbosity++;
        else if (!strcmp(argv[i], "-l") || !strcmp(argv[i], "--scan")) scan_only = 1;
        else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
            printf("usage: %s [-u URI] [-f HZ] [-r HZ] [-g DB|auto] [-n N] [-o FILE] [-s SHIFT] [-b HZ] [-v]\n", argv[0]);
            printf("       %s --scan      list contexts; exit 0 only if a usb:/ip: radio is openable\n", argv[0]);
            printf("       %s -u usb:1.4.4.3 -f 868200000 -r 4000000 -g 40 -n 2000000 -o 868.u8\n", argv[0]);
            printf("\nSee scripts/probe-pluto.sh, which builds and calls this.\n");
            return 0;
        }
        else { fprintf(stderr, "unknown option %s (try -h)\n", argv[i]); return 2; }
    }

    printf("pluto_probe %s, libiio %s\n", VERSION, libiio_version());
    if (shift < 0 || shift > 15) { fprintf(stderr, "shift must be 0..15\n"); return 2; }

    if (scan_only) {
        /* Machine-readable answer to "is a radio openable right now?", for probe-pluto.sh. */
        char *found = scan_for_context(1);
        printf("%s\n", found ? found : "NONE");
        free(found);
        return found ? 0 : 1;
    }

    if (!uri) {
        /* Default: the first usb: context, or failing that the first ip: one. The "local" backend is
         * deliberately never chosen: libiio always offers it on any host, so falling back to it would
         * mean opening a context with no radio in it and reporting a confusing "no ad9361-phy" from a
         * device that is simply not there. */
        uri = scan_for_context(0);
        if (uri) printf("no -u given; using the context the scan found: %s\n", uri);
    }

    if (!uri) {
        printf("\nNo usb: or ip: context is available. Contexts libiio can see:\n\n");
        list_contexts();
        printf("\nNothing here can receive. This is a device or permission problem, not an ogn-rf one:\n"
               "  * the radio is not on the bus, or\n"
               "  * it is in mass-storage mode and exposes no IIO device, or\n"
               "  * this user may not open the USB node (the udev rule is not installed).\n"
               "Run: ../scripts/probe-pluto.sh    - it names which of the three it is.\n");
        return 1;
    }
    if (verbosity > 1) { printf("\ncontexts:\n"); list_contexts(); }

    printf("\nopening %s\n", uri);
    struct iio_context *ctx = iio_create_context_from_uri(uri);
    if (!ctx) {
        printf("cannot open %s\n", uri);
        printf("The three usual reasons: the device is not on the bus; it is in mass-storage mode\n"
               "and exposes no IIO device; or this user may not open the USB node (needs the udev\n"
               "rule, see scripts/install-pluto-udev.sh).\n");
        return 1;
    }
    describe_context(ctx);

    struct phy p;
    if (find_phy(ctx, &p) < 0) { iio_context_destroy(ctx); return 1; }
    printf("\n");
    describe_phy(&p);

    /* ------------------------------------------------------------------------------------------ */
    /* configure                                                                                  */
    /* ------------------------------------------------------------------------------------------ */
    printf("\nconfiguring\n");
    if (p.lo) {
        if (iio_channel_attr_write_longlong(p.lo, "frequency", (long long)freq) < 0)
            fprintf(stderr, "  could not set the RX LO to %u Hz\n", freq);
    }
    if (p.rx0 && rate) {
        if (iio_channel_attr_write_longlong(p.rx0, "sampling_frequency", (long long)rate) < 0)
            fprintf(stderr, "  could not set the sample rate to %u Hz (below the chip's floor?)\n", rate);
    }
    if (p.rx0 && bw) {
        if (iio_channel_attr_write_longlong(p.rx0, "rf_bandwidth", (long long)bw) < 0)
            fprintf(stderr, "  could not set the bandwidth to %u Hz\n", bw);
    }
    if (gain_auto) {
        if (iio_device_attr_write(p.dev, "gain_control_mode", "slow_attack") < 0)
            fprintf(stderr, "  could not select automatic gain\n");
    } else if (gain >= 0 && p.rx0) {
        if (iio_device_attr_write(p.dev, "gain_control_mode", "manual") < 0)
            fprintf(stderr, "  could not select manual gain mode\n");
        if (iio_channel_attr_write_longlong(p.rx0, "hardwaregain", gain) < 0)
            fprintf(stderr, "  could not set gain to %lld dB\n", gain);
    }

    /* Read back what the hardware actually took: this is the honest answer, not what we asked for. */
    long long got_rate = 0, got_freq = 0, got_gain = 0;
    int have_rate = p.rx0 && read_ll(p.rx0, NULL, "sampling_frequency", &got_rate) == 0;
    int have_freq = p.lo  && read_ll(p.lo,  NULL, "frequency", &got_freq) == 0;
    int have_gain = p.rx0 && read_ll(p.rx0, NULL, "hardwaregain", &got_gain) == 0;
    printf("  requested %u Hz at %u Hz\n", freq, rate);
    printf("  applied   %lld Hz at %lld Hz%s\n",
           have_freq ? got_freq : -1, have_rate ? got_rate : -1,
           have_gain ? "" : "  (gain unread)");
    if (have_gain) printf("  gain      %lld dB %s\n", got_gain, gain_auto ? "(auto)" : "(manual)");
    if (have_rate && got_rate > 0 && got_rate != (long long)rate)
        printf("  NOTE: the device changed the requested rate to %lld Hz\n", got_rate);

    /* ------------------------------------------------------------------------------------------ */
    /* capture                                                                                    */
    /* ------------------------------------------------------------------------------------------ */
    iio_channel_enable(p.i);
    iio_channel_enable(p.q);
    for (unsigned int c = 0; c < iio_device_get_channels_count(p.rx); c++) {
        struct iio_channel *ch = iio_device_get_channel(p.rx, c);
        if (ch != p.i && ch != p.q && iio_channel_is_scan_element(ch))
            iio_channel_disable(ch);          /* keep the layout to exactly I and Q */
    }

    struct iio_buffer *buf = iio_device_create_buffer(p.rx, (size_t)want, false);
    if (!buf) {
        fprintf(stderr, "cannot create a %ld-sample buffer\n", want);
        iio_context_destroy(ctx); return 1;
    }

    /* Discard whatever is queued from before the retune, so the capture is the frequency we asked
     * for. This is the same "reset the buffer" discipline ogn-rf performs before every Read(). */
    for (int k = 0; k < 4; k++) {
        if (iio_buffer_refill(buf) < 0) break;
    }

    printf("\ncapturing %ld samples...\n", want);
    if (iio_buffer_refill(buf) < 0) {
        fprintf(stderr, "iio_buffer_refill() failed\n");
        iio_buffer_destroy(buf); iio_context_destroy(ctx); return 1;
    }

    const ptrdiff_t step = iio_buffer_step(buf);
    char *pi = iio_buffer_first(buf, p.i);
    char *pq = iio_buffer_first(buf, p.q);
    char *end = iio_buffer_end(buf);

    struct stats si, sq;
    stats_init(&si); stats_init(&sq);

    const double fullscale = ldexp(1.0, (int)p.bits - 1);   /* 12 bits -> 2048 */
    long long clipped = 0, n = 0;
    double mn = 1e30, mx = -1e30;

    FILE *out = NULL;
    if (outpath) {
        out = fopen(outpath, "wb");
        if (!out) { perror(outpath); }
    }

    for (; pi < end && pq < end && n < want; pi += step, pq += step, n++) {
        int16_t vi, vq;
        memcpy(&vi, pi, sizeof(vi));
        memcpy(&vq, pq, sizeof(vq));

        stats_add(&si, vi);
        stats_add(&sq, vq);
        if (vi < mn) mn = vi;
        if (vq < mn) mn = vq;
        if (vi > mx) mx = vi;
        if (vq > mx) mx = vq;

        /* Clipping is judged against the significant bits, not the 16-bit container. */
        if (fabs((double)vi) >= fullscale - 1 || fabs((double)vq) >= fullscale - 1) clipped++;

        if (out) {
            uint8_t o[2] = { (uint8_t)((vi >> shift) + 128), (uint8_t)((vq >> shift) + 128) };
            if (fwrite(o, 1, 2, out) != 2) { /* stopped writing; keep capturing */ }
        }
    }
    if (out) {
        fclose(out);
        printf("  wrote %lld I/Q pairs to %s (unsigned 8-bit, shift %d)\n", n, outpath, shift);
    }

    iio_channel_disable(p.i);
    iio_channel_disable(p.q);
    iio_buffer_destroy(buf);

    /* ------------------------------------------------------------------------------------------ */
    /* report                                                                                     */
    /* ------------------------------------------------------------------------------------------ */
    if (n == 0) {
        printf("\nno samples were delivered\n");
        iio_context_destroy(ctx);
        return 1;
    }

    const double rms_i = stats_rms(&si), rms_q = stats_rms(&sq);
    const double mean_i = stats_mean(&si), mean_q = stats_mean(&sq);
    const double peak = (mn > -mx ? -mn : mx);            /* largest magnitude seen */
    const double rms = sqrt((rms_i * rms_i + rms_q * rms_q) / 2.0);
    const double crest = rms > 0 ? peak / rms : 0.0;
    const double dur = have_rate && got_rate > 0 ? (double)n / (double)got_rate : 0.0;

    printf("\n%d samples (%.3f s at %lld Hz), %u-bit, full scale %.0f\n",
           (int)n, dur, have_rate ? got_rate : 0LL, p.bits, fullscale);
    printf("  I: mean %9.1f  rms %9.1f  min %8.0f  max %8.0f\n", mean_i, rms_i, si.mn, si.mx);
    printf("  Q: mean %9.1f  rms %9.1f  min %8.0f  max %8.0f\n", mean_q, rms_q, sq.mn, sq.mx);
    printf("  level: rms %.1f %%FS, peak %.1f %%FS, crest %.2f, clipped %lld samples\n",
           100.0 * rms / fullscale, 100.0 * peak / fullscale, crest, clipped);

    /* The checks that catch the common real failures. */
    int bad = 0;
    if (mx == mn) {
        printf("  FAIL: every sample is identical (%.0f) - the stream is stuck or all zeros.\n", mx);
        bad = 1;
    }
    if (rms == 0.0) {
        printf("  FAIL: rms is zero - no signal, and no noise either, which is not physical.\n");
        bad = 1;
    }
    if (clipped > (long long)(n / 100)) {
        printf("  FAIL: over 1%% of samples are at full scale - reduce the gain.\n");
        bad = 1;
    }
    if (fabs(mean_i) > 0.1 * fullscale || fabs(mean_q) > 0.1 * fullscale) {
        printf("  WARN: DC offset above 10%% of full scale (I %.0f, Q %.0f) - check the LO setting.\n",
               mean_i, mean_q);
    }
    if (crest < 3.0 && rms > 0.05 * fullscale) {
        printf("  WARN: crest factor %.2f is low for a noise floor - the front end may be compressing.\n", crest);
    }
    if (!bad) {
        printf("  PASS: a live stream with a plausible noise distribution.\n");
        printf("  Next: sweep -g to find where the noise floor sits and where it starts to clip,\n"
               "        and write the gain law down in docs/hardware.md.\n");
    }

    iio_context_destroy(ctx);
    return bad ? 1 : 0;
}
