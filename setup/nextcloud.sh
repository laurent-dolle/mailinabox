#!/bin/bash
# Nextcloud
##########################

source setup/functions.sh # load our functions
source /etc/mailinabox.conf # load global vars

# ### Installing Nextcloud

echo "Installing Nextcloud (contacts/calendar)..."

# Nextcloud core and app (plugin) versions to install.
# With each version we store a hash to ensure we install what we expect.

# Nextcloud core
# --------------
# * See https://nextcloud.com/changelog for the latest version.
# * Check https://docs.nextcloud.com/server/latest/admin_manual/installation/system_requirements.html
#   for whether it supports the version of PHP available on this machine.
# * Since Nextcloud only supports upgrades from consecutive major versions,
#   we automatically install intermediate versions as needed.
# * The hash is the SHA1 hash of the ZIP package, which you can find by just running this script and
#   copying it from the error message when it doesn't match what is below.
nextcloud_ver=22.2.3
nextcloud_hash=58d2d897ba22a057aa03d29c762c5306211fefd2

# Nextcloud apps
# --------------
# * Find the most recent tag that is compatible with the Nextcloud version above by
#   consulting the <dependencies>...<nextcloud> node at:
#   https://github.com/nextcloud-releases/contacts/blob/master/appinfo/info.xml
#   https://github.com/nextcloud-releases/calendar/blob/master/appinfo/info.xml
#   https://github.com/nextcloud/user_external/blob/master/appinfo/info.xml
# * The hash is the SHA1 hash of the ZIP package, which you can find by just running this script and
#   copying it from the error message when it doesn't match what is below.
contacts_ver=4.0.7
contacts_hash=8ab31d205408e4f12067d8a4daa3595d46b513e3
calendar_ver=3.0.5
calendar_hash=bbbb0f117fcdd2dbd2daa1d456b43dc534cec72f
user_external_ver=2.1.0
user_external_hash=6e5afe7f36f398f864bfdce9cad72200e70322aa

# Clear prior packages and install dependencies from apt.

apt-get purge -qq -y owncloud* # we used to use the package manager

apt_install memcached php php-fpm \
	php-cli php-sqlite3 php-gd php-imap php-curl php-pear curl \
	php-dev php-gd php-xml php-mbstring php-zip php-apcu php-json \
	php-intl php-imagick php-gmp php-bcmath

# Modification du fichier apcu_ini
echo apc.enable_cli=1 >> /etc/php/7.4/mods-available/apcu.ini

InstallNextcloud() {

	version=$1
	hash=$2
	version_contacts=$3
	hash_contacts=$4
	version_calendar=$5
	hash_calendar=$6
	version_user_external=${7:-}
	hash_user_external=${8:-}

	echo
	echo "Upgrading to Nextcloud version $version"
	echo

	# Download and verify
	wget_verify https://download.nextcloud.com/server/releases/nextcloud-$version.zip $hash /tmp/nextcloud.zip

	# Remove the current owncloud/Nextcloud
	rm -rf /usr/local/lib/owncloud

	# Extract ownCloud/Nextcloud
	unzip -q /tmp/nextcloud.zip -d /usr/local/lib
	mv /usr/local/lib/nextcloud /usr/local/lib/owncloud
	rm -f /tmp/nextcloud.zip

	# The two apps we actually want are not in Nextcloud core. Download the releases from
	# their github repositories.
	mkdir -p /usr/local/lib/owncloud/apps

	wget_verify https://github.com/nextcloud-releases/contacts/releases/download/v$version_contacts/contacts-v$version_contacts.tar.gz $hash_contacts /tmp/contacts.tgz
	tar xf /tmp/contacts.tgz -C /usr/local/lib/owncloud/apps/
	rm /tmp/contacts.tgz

	wget_verify https://github.com/nextcloud-releases/calendar/releases/download/v$version_calendar/calendar-v$version_calendar.tar.gz $hash_calendar /tmp/calendar.tgz
	tar xf /tmp/calendar.tgz -C /usr/local/lib/owncloud/apps/
	rm /tmp/calendar.tgz

	# Starting with Nextcloud 15, the app user_external is no longer included in Nextcloud core,
	# we will install from their github repository.
	if [ -n "$version_user_external" ]; then
		wget_verify https://github.com/nextcloud/user_external/releases/download/v$version_user_external/user_external-$version_user_external.tar.gz $hash_user_external /tmp/user_external.tgz
		tar -xf /tmp/user_external.tgz -C /usr/local/lib/owncloud/apps/
		rm /tmp/user_external.tgz
	fi

	# Fix weird permissions.
	chmod 750 /usr/local/lib/owncloud/{apps,config}

	# Create a symlink to the config.php in STORAGE_ROOT (for upgrades we're restoring the symlink we previously
	# put in, and in new installs we're creating a symlink and will create the actual config later).
	ln -sf $STORAGE_ROOT/owncloud/config.php /usr/local/lib/owncloud/config/config.php

	# Make sure permissions are correct or the upgrade step won't run.
	# $STORAGE_ROOT/owncloud may not yet exist, so use -f to suppress
	# that error.
	chown -f -R www-data.www-data $STORAGE_ROOT/owncloud /usr/local/lib/owncloud || /bin/true

	# If this isn't a new installation, immediately run the upgrade script.
	# Then check for success (0=ok and 3=no upgrade needed, both are success).
	if [ -e $STORAGE_ROOT/owncloud/owncloud.db ]; then
		# ownCloud 8.1.1 broke upgrades. It may fail on the first attempt, but
		# that can be OK.
		sudo -u www-data php /usr/local/lib/owncloud/occ upgrade
		if [ \( $? -ne 0 \) -a \( $? -ne 3 \) ]; then
			echo "Trying ownCloud upgrade again to work around ownCloud upgrade bug..."
			sudo -u www-data php /usr/local/lib/owncloud/occ upgrade
			if [ \( $? -ne 0 \) -a \( $? -ne 3 \) ]; then exit 1; fi
			sudo -u www-data php /usr/local/lib/owncloud/occ maintenance:mode --off
			echo "...which seemed to work."
		fi

		# Add missing indices. NextCloud didn't include this in the normal upgrade because it might take some time.
		sudo -u www-data php /usr/local/lib/owncloud/occ db:add-missing-indices

		# Run conversion to BigInt identifiers, this process may take some time on large tables.
		sudo -u www-data php /usr/local/lib/owncloud/occ db:convert-filecache-bigint --no-interaction
	fi
}

# Current Nextcloud Version, #1623
# Checking /usr/local/lib/owncloud/version.php shows version of the Nextcloud application, not the DB
# $STORAGE_ROOT/owncloud is kept together even during a backup.  It is better to rely on config.php than
# version.php since the restore procedure can leave the system in a state where you have a newer Nextcloud
# application version than the database.

# If the Nextcloud directory is missing (never been installed before, or the nextcloud version to be installed is different
# from the version currently installed, do the install/upgrade

# Stop php-fpm if running. If they are not running (which happens on a previously failed install), dont bail.
service php7.4-fpm stop &> /dev/null || /bin/true

# Backup the existing ownCloud/Nextcloud.
# Create a backup directory to store the current installation and database to
BACKUP_DIRECTORY=$STORAGE_ROOT/owncloud-backup/`date +"%Y-%m-%d-%T"`
mkdir -p "$BACKUP_DIRECTORY"
if [ -d /usr/local/lib/owncloud/ ]; then
	echo "Upgrading Nextcloud --- backing up existing installation, configuration, and database to directory to $BACKUP_DIRECTORY..."
	cp -r /usr/local/lib/owncloud "$BACKUP_DIRECTORY/owncloud-install"
fi
if [ -e $STORAGE_ROOT/owncloud/owncloud.db ]; then
	cp $STORAGE_ROOT/owncloud/owncloud.db $BACKUP_DIRECTORY
fi
if [ -e $STORAGE_ROOT/owncloud/config.php ]; then
	cp $STORAGE_ROOT/owncloud/config.php $BACKUP_DIRECTORY
fi

InstallNextcloud $nextcloud_ver $nextcloud_hash $contacts_ver $contacts_hash $calendar_ver $calendar_hash $user_external_ver $user_external_hash

# ### Configuring Nextcloud

# Setup Nextcloud if the Nextcloud database does not yet exist. Running setup when
# the database does exist wipes the database and user data.
if [ ! -f $STORAGE_ROOT/owncloud/owncloud.db ]; then
	# Create user data directory
	mkdir -p $STORAGE_ROOT/owncloud

	# Create an initial configuration file.
	instanceid=oc$(echo $PRIMARY_HOSTNAME | sha1sum | fold -w 10 | head -n 1)
	cat > $STORAGE_ROOT/owncloud/config.php <<EOF;
<?php
\$CONFIG = array (
  'datadirectory' => '$STORAGE_ROOT/owncloud',

  'instanceid' => '$instanceid',

  'forcessl' => true, # if unset/false, Nextcloud sends a HSTS=0 header, which conflicts with nginx config

  'overwritewebroot' => '/cloud',
  'overwrite.cli.url' => '/cloud',
  'user_backends' => array(
    array(
      'class' => 'OC_User_IMAP',
        'arguments' => array(
          '127.0.0.1', 143, null
         ),
    ),
  ),
  'memcache.local' => '\OC\Memcache\APCu',
  'mail_smtpmode' => 'sendmail',
  'mail_smtpsecure' => '',
  'mail_smtpauthtype' => 'LOGIN',
  'mail_smtpauth' => false,
  'mail_smtphost' => '',
  'mail_smtpport' => '',
  'mail_smtpname' => '',
  'mail_smtppassword' => '',
  'mail_from_address' => 'owncloud',
);
?>
EOF

	# Create an auto-configuration file to fill in database settings
	# when the install script is run. Make an administrator account
	# here or else the install can't finish.
	adminpassword=$(dd if=/dev/urandom bs=1 count=40 2>/dev/null | sha1sum | fold -w 30 | head -n 1)
	cat > /usr/local/lib/owncloud/config/autoconfig.php <<EOF;
<?php
\$AUTOCONFIG = array (
  # storage/database
  'directory' => '$STORAGE_ROOT/owncloud',
  'dbtype' => 'sqlite3',

  # create an administrator account with a random password so that
  # the user does not have to enter anything on first load of Nextcloud
  'adminlogin'    => 'root',
  'adminpass'     => '$adminpassword',
);
?>
EOF

	# Set permissions
	chown -R www-data.www-data $STORAGE_ROOT/owncloud /usr/local/lib/owncloud

	# Execute Nextcloud's setup step, which creates the Nextcloud sqlite database.
	# It also wipes it if it exists. And it updates config.php with database
	# settings and deletes the autoconfig.php file.
	(cd /usr/local/lib/owncloud; sudo -u www-data php /usr/local/lib/owncloud/index.php;)
fi

# Update config.php.
# * trusted_domains is reset to localhost by autoconfig starting with ownCloud 8.1.1,
#   so set it here. It also can change if the box's PRIMARY_HOSTNAME changes, so
#   this will make sure it has the right value.
# * Some settings weren't included in previous versions of Mail-in-a-Box.
# * We need to set the timezone to the system timezone to allow fail2ban to ban
#   users within the proper timeframe
# * We need to set the logdateformat to something that will work correctly with fail2ban
# * mail_domain' needs to be set every time we run the setup. Making sure we are setting
#   the correct domain name if the domain is being change from the previous setup.
# Use PHP to read the settings file, modify it, and write out the new settings array.
TIMEZONE=$(cat /etc/timezone)
CONFIG_TEMP=$(/bin/mktemp)
php <<EOF > $CONFIG_TEMP && mv $CONFIG_TEMP $STORAGE_ROOT/owncloud/config.php;
<?php
include("$STORAGE_ROOT/owncloud/config.php");

\$CONFIG['trusted_domains'] = array('$PRIMARY_HOSTNAME');

\$CONFIG['memcache.local'] = '\OC\Memcache\APCu';
\$CONFIG['overwrite.cli.url'] = '/cloud';
\$CONFIG['mail_from_address'] = 'administrator'; # just the local part, matches our master administrator address

\$CONFIG['logtimezone'] = '$TIMEZONE';
\$CONFIG['logdateformat'] = 'Y-m-d H:i:s';

\$CONFIG['mail_domain'] = '$PRIMARY_HOSTNAME';

\$CONFIG['user_backends'] = array(array('class' => 'OC_User_IMAP','arguments' => array('127.0.0.1', 143, null),),);

echo "<?php\n\\\$CONFIG = ";
var_export(\$CONFIG);
echo ";";
?>
EOF
chown www-data.www-data $STORAGE_ROOT/owncloud/config.php

# Enable/disable apps. Note that this must be done after the Nextcloud setup.
# The firstrunwizard gave Josh all sorts of problems, so disabling that.
# user_external is what allows Nextcloud to use IMAP for login. The contacts
# and calendar apps are the extensions we really care about here.
hide_output sudo -u www-data php /usr/local/lib/owncloud/console.php app:disable firstrunwizard
hide_output sudo -u www-data php /usr/local/lib/owncloud/console.php app:enable user_external
hide_output sudo -u www-data php /usr/local/lib/owncloud/console.php app:enable contacts
hide_output sudo -u www-data php /usr/local/lib/owncloud/console.php app:enable calendar

# When upgrading, run the upgrade script again now that apps are enabled. It seems like
# the first upgrade at the top won't work because apps may be disabled during upgrade?
# Check for success (0=ok, 3=no upgrade needed).
sudo -u www-data php /usr/local/lib/owncloud/occ upgrade
if [ \( $? -ne 0 \) -a \( $? -ne 3 \) ]; then exit 1; fi

# Set PHP FPM values to support large file uploads
# (semicolon is the comment character in this file, hashes produce deprecation warnings)
tools/editconf.py /etc/php/7.4/fpm/php.ini -c ';' \
	upload_max_filesize=16G \
	post_max_size=16G \
	output_buffering=16384 \
	memory_limit=512M \
	max_execution_time=600 \
	short_open_tag=On

# Set Nextcloud recommended opcache settings
tools/editconf.py /etc/php/7.4/cli/conf.d/10-opcache.ini -c ';' \
	opcache.enable=1 \
	opcache.enable_cli=1 \
	opcache.interned_strings_buffer=8 \
	opcache.max_accelerated_files=10000 \
	opcache.memory_consumption=128 \
	opcache.save_comments=1 \
	opcache.revalidate_freq=1

# If apc is explicitly disabled we need to enable it
if grep -q apc.enabled=0 /etc/php/7.4/mods-available/apcu.ini; then
	tools/editconf.py /etc/php/7.4/mods-available/apcu.ini -c ';' \
		apc.enabled=1
fi

# Set up a cron job for Nextcloud.
cat > /etc/cron.d/mailinabox-nextcloud << EOF;
#!/bin/bash
# Mail-in-a-Box
*/5 * * * *	root	sudo -u www-data php -f /usr/local/lib/owncloud/cron.php
EOF
chmod +x /etc/cron.d/mailinabox-nextcloud

# Remove previous hourly cronjob
rm -f /etc/cron.hourly/mailinabox-owncloud

# There's nothing much of interest that a user could do as an admin for Nextcloud,
# and there's a lot they could mess up, so we don't make any users admins of Nextcloud.
# But if we wanted to, we would do this:
# ```
# for user in $(tools/mail.py user admins); do
#	 sqlite3 $STORAGE_ROOT/owncloud/owncloud.db "INSERT OR IGNORE INTO oc_group_user VALUES ('admin', '$user')"
# done
# ```

# Enable PHP modules and restart PHP.
restart_service php7.4-fpm
