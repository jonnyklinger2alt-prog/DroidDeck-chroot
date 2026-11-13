#!/system/bin/sh
self="$0"

quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

if [ "$1" != "--as-root" ] && [ "$1" != "--in-ns" ]; then
    if [ "$(id -u)" = 0 ]; then
        exec /system/bin/sh "$self" --as-root "$PPID" "$@"
    fi
    args=""
    for a in "$@"; do args="$args $(quote "$a")"; done
    exec su -p -c "exec /system/bin/sh $(quote "$self") --as-root $$$args"
fi

phase="$1"
shift
if [ "$phase" = --as-root ]; then
    caller="$1"
    shift
fi
pidns="$PIDNS"

root= cwd=/root uid=0 gid=0 groups= hostname= fake=0 log=
while [ $# -gt 0 ]; do
    case "$1" in
        --root) root="$2"; shift 2 ;;
        --cwd) cwd="$2"; shift 2 ;;
        --uid) uid="$2"; shift 2 ;;
        --gid) gid="$2"; shift 2 ;;
        --groups) groups="$2"; shift 2 ;;
        --hostname) hostname="$2"; shift 2 ;;
        --fake-root) fake=1; shift ;;
        --log) log="$2"; shift 2 ;;
        *) break ;;
    esac
done
say() {
    [ -n "$log" ] && echo "chroot: $*" >>"$log"
    echo "chroot: $*" >&2
}

if [ -z "$root" ] || [ ! -d "$root" ]; then
    say "no root filesystem at '$root'"
    exit 127
fi

if [ "$phase" = --as-root ]; then
    for tool in unshare mount chroot; do
        command -v "$tool" >/dev/null || say "the host has no $tool"
    done
    set -- --root "$root" --cwd "$cwd" --uid "$uid" --gid "$gid" --groups "$groups" --hostname "$hostname" --log "$log" "$@"
    [ "$fake" = 1 ] && set -- --fake-root "$@"
    exec 3<&0
    if unshare -m -p -f -u true 2>/dev/null; then
        PIDNS=1 unshare -m -p -f -u /system/bin/sh "$self" --in-ns "$@" <&3 3<&- &
    else
        PIDNS=0 unshare -m -u /system/bin/sh "$self" --in-ns "$@" <&3 3<&- &
    fi
    child=$!
    exec 3<&-

    stop() {
        init=$(cat /proc/$child/task/$child/children 2>/dev/null)
        if [ -n "$init" ] && [ "$(readlink /proc/$init/ns/pid)" != "$(readlink /proc/self/ns/pid)" ]; then
            ns=$(readlink /proc/$init/ns/pid)
            for p in /proc/[0-9]*; do
                [ "$(readlink $p/ns/pid 2>/dev/null)" = "$ns" ] && kill -TERM "${p#/proc/}" 2>/dev/null
            done
            sleep 3
            kill -KILL "$init" 2>/dev/null
        else
            kill -TERM "$child" 2>/dev/null
            sleep 3
        fi
        kill -KILL "$child" 2>/dev/null
    }

    (
        while kill -0 "$child" 2>/dev/null; do
            if [ -n "$caller" ] && [ ! -d "/proc/$caller" ]; then
                stop
                break
            fi
            sleep 1
        done
    ) </dev/null >/dev/null 2>&1 &
    watchdog=$!
    trap 'stop' TERM HUP INT
    wait "$child"
    status=$?
    kill "$watchdog" 2>/dev/null
    say "guest exited with status $status"
    # Real root writes uid 0 files, but the app owns the rootfs and must be able to update and remove it.
    if [ "$fake" = 1 ]; then
        find "$root" -xdev \( -user 0 -o -group 0 \) -exec chown -h "$uid:$gid" {} + 2>/dev/null
    fi
    exit $status
fi

mount --make-rprivate / 2>/dev/null || mount -o remount,rprivate / 2>/dev/null
[ -n "$hostname" ] && hostname "$hostname" 2>/dev/null

target_for() {
    t="$root$1"
    if [ -d "$2" ]; then
        [ -d "$t" ] || { mkdir -p "$t" && chown "$uid:$gid" "$t"; }
    else
        [ -d "${t%/*}" ] || mkdir -p "${t%/*}"
        [ -e "$t" ] || { touch "$t" && chown "$uid:$gid" "$t"; }
    fi 2>/dev/null
}

while [ "$1" = -b ]; do
    spec="$2"
    shift 2
    src="${spec%%:*}"
    dst="${spec#*:}"
    case "$src" in
        /proc/self/*)
            [ -e "$root$dst" ] || [ -L "$root$dst" ] || ln -s "$src" "$root$dst" 2>/dev/null
            continue ;;
    esac
    if [ "$dst" = /proc ] && [ "$pidns" = 1 ]; then
        target_for /proc /proc
        mount -t proc proc "$root/proc" && continue
    fi
    [ -e "$src" ] || continue
    target_for "$dst" "$src"
    case "$dst" in
        /dev|/sys|/proc) opt=rbind ;;
        *) opt=bind ;;
    esac
    mount -o "$opt" "$src" "$root$dst" 2>/dev/null || mount "--$opt" "$src" "$root$dst" 2>/dev/null \
        || say "cannot bind $src to $dst"
done

if [ $# -eq 0 ]; then
    say "no command"
    exit 127
fi
if [ ! -e "$root/bin/sh" ]; then
    say "the root filesystem has no /bin/sh"
    exit 127
fi

if [ "$fake" != 1 ]; then
    if [ ! -e "$root/usr/bin/setpriv" ]; then
        say "the root filesystem has no /usr/bin/setpriv; install util-linux"
        exit 127
    fi
    if [ -n "$groups" ]; then groupopt="--groups=$groups"; else groupopt=--clear-groups; fi
    set -- /usr/bin/setpriv --reuid="$uid" --regid="$gid" "$groupopt" --inh-caps=-all -- "$@"
fi
enter='cd "$1" 2>/dev/null || cd /; shift; exec "$@"'
exec 3<&0
chroot "$root" /bin/sh -c "$enter" sh "$cwd" "$@" <&3 3<&- &
guest=$!
exec 3<&-
trap 'kill -TERM $guest 2>/dev/null' TERM HUP INT
wait "$guest"
status=$?
while [ $status -gt 128 ] && kill -0 "$guest" 2>/dev/null; do
    wait "$guest"
    status=$?
done
exit $status
