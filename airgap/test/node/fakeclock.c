/*
 * fakeclock.c: an LD_PRELOAD shim for the node tests. Every process that
 * loads it sees the wall clock (CLOCK_REALTIME, gettimeofday, time) shifted
 * by the whole seconds in the file $FAKECLOCK_FILE, re-read on each call, so
 * a stub that "sets the clock" (date-set, chronyc makestep) writes a new
 * offset and every later reading moves, bash's SECONDS included, as with a
 * real step. Monotonic clocks are not shifted. The test host's clock is
 * never touched. run.sh builds it with cc into its temp dir.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <time.h>

static long fake_offset(void)
{
	const char *f = getenv("FAKECLOCK_FILE");
	FILE *p;
	long o = 0;

	if (!f || !(p = fopen(f, "r")))
		return 0;
	if (fscanf(p, "%ld", &o) != 1)
		o = 0;
	fclose(p);
	return o;
}

int clock_gettime(clockid_t c, struct timespec *ts)
{
	static int (*real)(clockid_t, struct timespec *);
	int rc;

	if (!real)
		real = (int (*)(clockid_t, struct timespec *))dlsym(RTLD_NEXT, "clock_gettime");
	rc = real(c, ts);
	if (rc == 0 && (c == CLOCK_REALTIME || c == CLOCK_REALTIME_COARSE))
		ts->tv_sec += fake_offset();
	return rc;
}

int gettimeofday(struct timeval *tv, void *tz)
{
	static int (*real)(struct timeval *, void *);
	int rc;

	if (!real)
		real = (int (*)(struct timeval *, void *))dlsym(RTLD_NEXT, "gettimeofday");
	rc = real(tv, tz);
	if (rc == 0)
		tv->tv_sec += fake_offset();
	return rc;
}

time_t time(time_t *t)
{
	struct timespec ts;

	clock_gettime(CLOCK_REALTIME, &ts);
	if (t)
		*t = ts.tv_sec;
	return ts.tv_sec;
}
