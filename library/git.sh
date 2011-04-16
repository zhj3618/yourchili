#!/bin/bash



##################
# Git / Gitolite #
##################


function git_install
{
	aptitude install -y git
}

function gitolite_install
{
	aptitude install -y ssh 
	git_install
	if [ ! -d "/srv/git" ] ; then
		
		#make sure root has a pubkey
		if [ ! -e /root/.ssh/id_rsa ] ; then
			rm -rf /root/.ssh/gitolite_admin_id_rsa*
			rm -rf /root/.ssh/git_user_id_rsa*
			printf "/root/.ssh/gitolite_admin_id_rsa\n\n\n\n\n" | ssh-keygen -t rsa -P "" 
			printf "/root/.ssh/git_user_id_rsa\n\n\n\n\n" | ssh-keygen -t rsa -P ""
			
			#give root gitolite admin priviledges
			ln -s /root/.ssh/gitolite_admin_id_rsa /root/.ssh/id_rsa 
			ln -s /root/.ssh/gitolite_admin_id_rsa.pub /root/.ssh/id_rsa.pub
		fi
		
		#create git user
		adduser \
			--system \
			--shell /bin/sh \
			--gecos 'git version control' \
			--ingroup www-data \
			--disabled-password \
			--home /srv/git \
			git
		if [ ! -d /srv/git ] ; then
			mkdir -p /srv/git
			chown git:www-data /srv/git
		fi

		#install gitolite
		local curdir=$(pwd)
		cp /root/.ssh/gitolite_admin_id_rsa.pub /tmp/gitolite_admin_id_rsa.pub
		cd /tmp
		git clone git://github.com/sitaramc/gitolite.git
		cd gitolite
		git checkout "v2.0"
		mkdir -p /usr/local/share/gitolite/conf /usr/local/share/gitolite/hooks /srv/git/repositories
		src/gl-system-install /usr/local/bin /usr/local/share/gitolite/conf /usr/local/share/gitolite/hooks
		chown -R git:www-data /srv/git
		su git -c "gl-setup -q /tmp/gitolite_admin_id_rsa.pub"

		#remove testing repo
		cd /tmp
		rm -rf gitolite-admin
		sudo su -c "git clone git@localhost:gitolite-admin.git"
		cd gitolite-admin
		local testing_line=$(cat conf/gitolite.conf | grep -n "repo.*testing" | sed 's/:.*$//g')
		if [ -n "$testing_line" ] ; then
			head -n $(( $testing_line - 1 )) conf/gitolite.conf > conf/gitolite.tmp
			mv conf/gitolite.tmp conf/gitolite.conf
			sudo su -c "git commit -a -m \"add project $PROJ_ID\""
			sudo su -c "git push"
		fi
		rm -rf /srv/git/repositories/testing.git
		cd /tmp
		rm -rf gitolite-admin



		#authorize special git_user_id_rsa ssh key to be able to login as git user (useful for using ssh to run commands necessray for smart http)
		cat /srv/git/.ssh/authorized_keys /root/.ssh/git_user_id_rsa.pub >/srv/git/.ssh/new_auth
		mv /srv/git/.ssh/new_auth /srv/git/.ssh/authorized_keys
		chown git:www-data /srv/git/.ssh/authorized_keys
		chmod 600 /srv/git/.ssh/authorized_keys


		#install git daemon
		#(only exports public projects, with git-daemon-export-ok file, so by default it is secure)
		cat << 'EOF' > /etc/init.d/git-daemon
#!/bin/sh

test -f /usr/lib/git-core/git-daemon || exit 0

. /lib/lsb/init-functions

GITDAEMON_OPTIONS="--reuseaddr --verbose --base-path=/srv/git/repositories/ --detach"

case "$1" in
start)  log_daemon_msg "Starting git-daemon"

        start-stop-daemon --start -c git:www-data --quiet --background \
                     --exec /usr/lib/git-core/git-daemon -- ${GITDAEMON_OPTIONS}

        log_end_msg $?
        ;;
stop)   log_daemon_msg "Stopping git-daemon"

        start-stop-daemon --stop --quiet --name git-daemon

        log_end_msg $?
        ;;
*)      log_action_msg "Usage: /etc/init.d/git-daemon {start|stop}"
        exit 2
        ;;
esac
exit 0
EOF
		chmod 755 "/etc/init.d/git-daemon"
		update-rc.d git-daemon defaults
		/etc/init.d/git-daemon start

		cd "$curdir"

	fi
}

function create_git
{
	local PROJ_ID=$1 ; shift ;
	local PROJ_IS_PUBLIC=$1 ; shift ;

	#optional -- only if we need to set up a post-recieve chiliproject hook
	local CHILI_INSTALL_PATH=$1 ; shift ;

	
	local curdir=$(pwd)


	#does nothing if git/gitolite is already installed
	git_install
	gitolite_install


	#create git repository
	cd /tmp
	rm -rf gitolite-admin
	sudo su -c "git clone git@localhost:gitolite-admin.git"
	cd gitolite-admin
	echo ""                                          >>conf/gitolite.conf
	echo "repo    $PROJ_ID"                          >>conf/gitolite.conf
	echo "        RW+     =   gitolite_admin_id_rsa" >>conf/gitolite.conf
	if [ -n "$PROJ_IS_PUBLIC" ] ; then
		echo "        R     =   daemon"          >>conf/gitolite.conf
	fi
	sudo su -c "git commit -a -m \"add project $PROJ_ID\""
	sudo su -c "git push"
	cd /tmp
	rm -rf gitolite-admin

	
	if [ -n "$CHILI_INSTALL_PATH" ] ; then
		#post-receive hook
		pr_file="/srv/git/repositories/$PROJ_ID.git/hooks/post-receive"
		cat << EOF > "$pr_file"
cd "$CHILI_INSTALL_PATH"
ruby script/runner "Repository.fetch_changesets" -e production
EOF

		chmod    775 "$pr_file"
		chown git:www-data "$pr_file"
	fi

	cd "$curdir"

}

