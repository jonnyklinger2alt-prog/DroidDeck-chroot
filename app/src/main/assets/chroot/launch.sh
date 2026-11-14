#!/system/bin/sh
self="$0"

quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

find_su() {
    command -v su && return
    for candidate in /system/bin/su /system/xbin/su /debug_ramdisk/su /sbin/su /su/bin/su; do
        [ -e "$candidate" ] && { echo "$candidate"; return; }
    done
    echo su
}

if [ "$1" != "--as-root" ] && [ "$1" != "--in-ns" ]; then
    if [ "$(id -u)" = 0 ]; then
        exec /system/bin/sh "$self" --as-root "$PPID" "" "$@"
    fi
    # Not every root manager's su keeps the caller's environment, so it travels in a private file.
    umask 077
    envfile="${self%/*}/env.$$"
    export -p >"$envfile"
    args=""
    for a in "$@"; do args="$args $(quote "$a")"; done
    exec "$(find_su)" -c "exec /system/bin/sh $(quote "$self") --as-root $$ $(quote "$envfile")$args"
fi

phase="$1"
shift
if [ "$phase" = --as-root ]; then
    umask 022
    caller="$1"
    envfile="$2"
    shift 2
    if [ -n "$envfile" ]; then
        while IFS= read -r line; do
            case "$line" in
                "export "*=*) entry=${line#export } ;;
                "typeset -x "*=*) entry=${line#typeset -x } ;;
                *) continue ;;
            esac
            name=${entry%%=*}
            case "$name" in
                ''|*[!A-Za-z0-9_]*|[0-9]*|_|PPID|PWD|OLDPWD|SHLVL|RANDOM|SECONDS|LINENO) continue ;;
            esac
            eval "export $entry" 2>/dev/null
        done <"$envfile"
        rm -f "$envfile"
    fi
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

bb=
for candidate in "$BUSYBOX" /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
        "$(command -v busybox)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { bb="$candidate"; break; }
done
mnt() {
    if [ -n "$bb" ]; then "$bb" mount "$@"; else mount "$@"; fi
}

l2s_path() {
    case "$2" in
        */files/linuxfs/*) echo "$root/${2#*/files/linuxfs/}" ;;
        /*) echo "$root$2" ;;
        *) echo "$1/$2" ;;
    esac
}

# The installer stands in for hard links Android refuses an app with proot's link2symlink layout;
# outside proot multi-call binaries see the .l2s names, so turn them back into real hard links.
hardlink_l2s() {
    marker="$root/etc/droiddeck/.l2s-hardlinked"
    lock="$root/etc/droiddeck/.l2s-lock"
    [ -e "$marker" ] && return
    mkdir -p "$root/etc/droiddeck"
    waited=0
    until mkdir "$lock" 2>/dev/null; do
        [ -e "$marker" ] && return
        [ $waited -ge 120 ] && break
        sleep 1
        waited=$((waited + 1))
    done
    if [ ! -e "$marker" ]; then
        find "$root" -xdev -type l ! -name '.l2s.*' 2>/dev/null | while IFS= read -r link; do
            to=$(readlink "$link")
            case "${to##*/}" in .l2s.*) ;; *) continue ;; esac
            mid=$(l2s_path "${link%/*}" "$to")
            [ -L "$mid" ] || continue
            data=$(l2s_path "${mid%/*}" "$(readlink "$mid")")
            [ -f "$data" ] && [ ! -L "$data" ] || continue
            ln -f "$data" "$link.dd-l2s" && mv -f "$link.dd-l2s" "$link" || say "cannot hard link $link"
        done
        find "$root" -xdev -name '.l2s.*' -type l -exec rm -f {} + 2>/dev/null
        find "$root" -xdev -name '.l2s.*' -type f -links +1 -exec rm -f {} + 2>/dev/null
        touch "$marker" && chown "$uid:$gid" "$marker"
    fi
    rmdir "$lock" 2>/dev/null
}

if [ "$phase" = --as-root ]; then
    for tool in unshare chroot; do
        command -v "$tool" >/dev/null || say "the host has no $tool"
    done
    hardlink_l2s
    set -- --root "$root" --cwd "$cwd" --uid "$uid" --gid "$gid" --groups "$groups" --hostname "$hostname" --log "$log" "$@"
    [ "$fake" = 1 ] && set -- --fake-root "$@"
    exec 3<&0
    if unshare -m -p -f -u true 2>/dev/null; then
        BUSYBOX="$bb" PIDNS=1 unshare -m -p -f -u /system/bin/sh "$self" --in-ns "$@" <&3 3<&- &
    else
        BUSYBOX="$bb" PIDNS=0 unshare -m -u /system/bin/sh "$self" --in-ns "$@" <&3 3<&- &
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

# Mounts made below must never propagate back into Android's own mount namespace.
mnt --make-rprivate / 2>/dev/null || mount -o rslave / 2>/dev/null
if grep -q shared: /proc/self/mountinfo; then
    say "cannot make the mount namespace private; refusing to mount into the shared namespace"
    exit 126
fi
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

bind() {
    if [ -n "$bb" ]; then
        "$bb" mount "--$3" "$1" "$2" 2>&1
    elif [ -c "$1" ] || [ -b "$1" ]; then
        if [ -c "$1" ]; then kind=c; else kind=b; fi
        numbers=$(stat -c '%t %T' "$1") || return 1
        rm -f "$2" && mknod "$2" "$kind" $((0x${numbers% *})) $((0x${numbers#* })) 2>&1 \
            && chmod "$(stat -c %a "$1")" "$2" && chown "$(stat -c %u:%g "$1")" "$2"
    else
        mount -o "$3" "$1" "$2" 2>&1
    fi
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
        mnt -t proc proc "$root/proc" && continue
    fi
    [ -e "$src" ] || continue
    target_for "$dst" "$src"
    if [ ! -e "$root$dst" ]; then
        say "skipped $dst: it cannot be created there"
        continue
    fi
    case "$dst" in
        /dev|/sys|/proc) opt=rbind ;;
        *) opt=bind ;;
    esac
    err=$(bind "$src" "$root$dst" "$opt") || say "cannot bind $src to $dst: $err"
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
if [ -n "$log" ]; then
    chroot "$root" /bin/sh -c "$enter" sh "$cwd" "$@" <&3 3<&- >>"$log" 2>&1 &
else
    chroot "$root" /bin/sh -c "$enter" sh "$cwd" "$@" <&3 3<&- &
fi
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
