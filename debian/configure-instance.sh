#! /bin/sh -e

# This helper script is used by the postfix init scripts,
# upstart jobs, systemd services, openrc scripts, etc. in
# prepping the instance of postfix to be started.

# It was originally part of the postfix init script, which
# was written by LaMont Jones <lamont@debian.org>, and based
# off of the sendmail init script.

INSTANCE="$1"

SYNC_CHROOT="y"

if test -r /etc/default/postfix; then
	. /etc/default/postfix
fi

if [ "X$INSTANCE" = X ] || [ "X$INSTANCE" = "X-" ]; then
	POSTCONF="postconf -o inet_interfaces="
else
	POSTCONF="postconf -o inet_interfaces= -c /etc/$INSTANCE"
fi

# if you set myorigin to 'ubuntu.com' or 'debian.org', it's wrong, and annoys the admins of
# those domains.  See also sender_canonical_maps.

MYORIGIN=$($POSTCONF -hx myorigin | tr 'A-Z' 'a-z')
if [ "X${MYORIGIN#/}" != "X${MYORIGIN}" ]; then
	MYORIGIN=$(tr 'A-Z' 'a-z' < $MYORIGIN)
fi
if [ "X$MYORIGIN" = Xubuntu.com ] || [ "X$MYORIGIN" = Xdebian.org ]; then
	echo "Invalid \$myorigin ($MYORIGIN), refusing to start"
	exit 1
fi

config_dir=$($POSTCONF -hx config_directory)
# see if anything is running chrooted.
NEED_CHROOT=$(awk '/^[0-9a-z]/ && ($5 ~ "[-yY]") { print "y"; exit}' ${config_dir}/master.cf)

if [ -n "$NEED_CHROOT" ] && [ -n "$SYNC_CHROOT" ]; then
	# Make sure that the chroot environment is set up correctly.
	umask 022
	queue_dir=$($POSTCONF -hx queue_directory)
	cd "$queue_dir"

	# copy the smtp CA path if specified
	sca_path=$($POSTCONF -hx smtp_tls_CApath)
	case "$sca_path" in
	    '') :;; # no sca_path
	    $queue_dir/*) :;;  # skip stuff already in chroot
	    *)
		if test -d "$sca_path"; then
		    dest_dir="$queue_dir/${sca_path#/}"
		    # strip any/all trailing /
		    while [ "${dest_dir%/}" != "${dest_dir}" ]; do
			dest_dir="${dest_dir%/}"
		    done
		    new=0
		    if test -d "$dest_dir"; then
			# write to a new directory ...
			dest_dir="${dest_dir}.NEW"
			new=1
		    fi
		    mkdir --parent ${dest_dir}
		    # handle files in subdirectories
		    (cd "$sca_path" && find . -name '*.pem' -not -xtype l -print0 | cpio -0pdL --quiet "$dest_dir") 2>/dev/null ||
		        (echo failure copying certificates; exit 1)
		    c_rehash "$dest_dir" >/dev/null 2>&1
		    if [ "$new" = 1 ]; then
			# and replace the old directory
			rm -rf "${dest_dir%.NEW}"
			mv "$dest_dir" "${dest_dir%.NEW}"
		    fi
		fi
		;;
	esac

	# copy the smtpd CA path if specified
	dca_path=$($POSTCONF -hx smtpd_tls_CApath)
	case "$dca_path" in
	    '') :;; # no dca_path
	    $queue_dir/*) :;;  # skip stuff already in chroot
	    *)
		if test -d "$dca_path"; then
		    dest_dir="$queue_dir/${dca_path#/}"
		    # strip any/all trailing /
		    while [ "${dest_dir%/}" != "${dest_dir}" ]; do
			dest_dir="${dest_dir%/}"
		    done
		    new=0
		    if test -d "$dest_dir"; then
			# write to a new directory ...
			dest_dir="${dest_dir}.NEW"
			new=1
		    fi
		    mkdir --parent ${dest_dir}
		    # handle files in subdirectories
		    (cd "$dca_path" && find . -name '*.pem' -not -xtype l -print0 | cpio -0pdL --quiet "$dest_dir") 2>/dev/null ||
		        (echo failure copying certificates; exit 1)
		    c_rehash "$dest_dir" >/dev/null 2>&1
		    if [ "$new" = 1 ]; then
			# and replace the old directory
			rm -rf "${dest_dir%.NEW}"
			mv "$dest_dir" "${dest_dir%.NEW}"
		    fi
		fi
		;;
	esac

	# if we're using unix:passwd.byname, then we need to add etc/passwd.
	local_maps=$($POSTCONF -hx local_recipient_maps)
	if [ "X$local_maps" != "X${local_maps#*unix:passwd.byname}" ]; then
	    if [ "X$local_maps" = "X${local_maps#*proxy:unix:passwd.byname}" ]; then
		sed 's/^\([^:]*\):[^:]*/\1:x/' /etc/passwd > etc/passwd
		chmod a+r etc/passwd
	    fi
	fi

	FILES="etc/localtime etc/services etc/resolv.conf etc/hosts \
	    etc/host.conf etc/nsswitch.conf etc/nss_mdns.config"
	for file in $FILES; do
	    [ -d ${file%/*} ] || mkdir -p ${file%/*}
	    if [ -f /${file} ]; then rm -f ${file} && cp /${file} ${file}; fi
	    if [ -f  ${file} ]; then chmod a+rX ${file}; fi
	done
	# ldaps needs this. debian bug 572841
	(echo /dev/random; echo /dev/urandom) | cpio -pdL --quiet . 2>/dev/null || true
	rm -f usr/lib/zoneinfo/localtime
	mkdir -p usr/lib/zoneinfo
	ln -sf /etc/localtime usr/lib/zoneinfo/localtime

	LIBLIST=$(for name in gcc_s nss resolv; do
	    for f in /lib/*/lib${name}*.so* /lib/lib${name}*.so*; do
	       if [ -f "$f" ]; then  echo ${f#/}; fi;
	    done;
	done)

	if [ -n "$LIBLIST" ]; then
	    for f in $LIBLIST; do
		rm -f "$f"
	    done
	    tar cf - -C / $LIBLIST 2>/dev/null |tar xf -
	fi
fi
