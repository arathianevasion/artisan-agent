# Starting a process that outlives its caller, the one way the pipeline does
# it (run-ticket.sh's workers, merge-gate.sh's gate): a new session (setsid,
# or perl's POSIX::setsid where there is no setsid command) under nohup, with
# stdin from /dev/null, so neither the caller exiting, a hang-up, nor the Bash
# tool's time cap stops it. The process writes its own pid file once it is
# up; the caller waits for it. Sourced, never run.
#
# Portable to bash 3.2 (macOS) and Linux.

# detach command...: run in a new session, never returning its status.
detach() {
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@"
  else
    perl -MPOSIX -e 'POSIX::setsid() != -1 or die "setsid: $!\n"; exec @ARGV or die "exec $ARGV[0]: $!\n"' -- "$@"
  fi
}

# detach_start pid-file log command...: start command detached (nohup, in a
# new session, output appended to log) and wait up to 10 seconds for it to
# write its pid to pid-file. Prints the pid; 1 if it never came up.
detach_start() {
  local pid_file="$1" log="$2" i=0
  shift 2
  detach nohup "$@" </dev/null >>"$log" 2>&1 &
  while [ ! -s "$pid_file" ]; do
    i=$((i + 1))
    [ "$i" -le 100 ] || return 1
    sleep 0.1
  done
  cat "$pid_file"
}

# detach_write_pid pid-file: the detached process records its own pid,
# atomically, so the caller never reads half of it.
detach_write_pid() {
  echo $$ >"$1.tmp" && mv "$1.tmp" "$1"
}
