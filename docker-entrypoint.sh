#!/bin/bash

set -e

: ${MEDIAWIKI_SITE_NAME:=MediaWiki}
: ${MEDIAWIKI_DB_TYPE:=mysql}

if [ -z "$MEDIAWIKI_DB_HOST" ]; then
	if [ -n "$MYSQL_PORT_3306_TCP_ADDR" ]; then
		MEDIAWIKI_DB_HOST=$MYSQL_PORT_3306_TCP_ADDR
	elif [ -n "$POSTGRES_PORT_5432_TCP_ADDR" ]; then
		MEDIAWIKI_DB_TYPE=postgres
		MEDIAWIKI_DB_HOST=$POSTGRES_PORT_5432_TCP_ADDR
	elif [ -n "$DB_PORT_3306_TCP_ADDR" ]; then
		MEDIAWIKI_DB_HOST=$DB_PORT_3306_TCP_ADDR
	else
		echo >&2 'error: missing MEDIAWIKI_DB_HOST environment variable'
		echo >&2 '  Did you forget to --link your database?'
		exit 1
	fi
fi

if [ -z "$MEDIAWIKI_DB_USER" ]; then
	if [ "$MEDIAWIKI_DB_TYPE" = "mysql" ]; then
		echo >&2 'info: missing MEDIAWIKI_DB_USER environment variable, defaulting to "root"'
		MEDIAWIKI_DB_USER=root
	elif [ "$MEDIAWIKI_DB_TYPE" = "postgres" ]; then
		echo >&2 'info: missing MEDIAWIKI_DB_USER environment variable, defaulting to "postgres"'
		MEDIAWIKI_DB_USER=postgres
	else
		echo >&2 'error: missing required MEDIAWIKI_DB_USER environment variable'
		exit 1
	fi
fi

if [ -z "$MEDIAWIKI_DB_PASSWORD" ]; then
	if [ -n "$MYSQL_ENV_MYSQL_ROOT_PASSWORD" ]; then
		MEDIAWIKI_DB_PASSWORD=$MYSQL_ENV_MYSQL_ROOT_PASSWORD
	elif [ -n "$POSTGRES_ENV_POSTGRES_PASSWORD" ]; then
		MEDIAWIKI_DB_PASSWORD=$POSTGRES_ENV_POSTGRES_PASSWORD
	elif [ -n "$DB_ENV_MYSQL_ROOT_PASSWORD" ]; then
		MEDIAWIKI_DB_PASSWORD=$DB_ENV_MYSQL_ROOT_PASSWORD
	else
		echo >&2 'error: missing required MEDIAWIKI_DB_PASSWORD environment variable'
		echo >&2 '  Did you forget to -e MEDIAWIKI_DB_PASSWORD=... ?'
		echo >&2
		echo >&2 '  (Also of interest might be MEDIAWIKI_DB_USER and MEDIAWIKI_DB_NAME)'
		exit 1
	fi
fi

: ${MEDIAWIKI_DB_NAME:=mediawiki}

if [ -z "$MEDIAWIKI_DB_PORT" ]; then
	if [ -n "$MYSQL_PORT_3306_TCP_PORT" ]; then
		MEDIAWIKI_DB_PORT=$MYSQL_PORT_3306_TCP_PORT
	elif [ -n "$POSTGRES_PORT_5432_TCP_PORT" ]; then
		MEDIAWIKI_DB_PORT=$POSTGRES_PORT_5432_TCP_PORT
	elif [ -n "$DB_PORT_3306_TCP_PORT" ]; then
		MEDIAWIKI_DB_PORT=$DB_PORT_3306_TCP_PORT
	elif [ "$MEDIAWIKI_DB_TYPE" = "mysql" ]; then
		MEDIAWIKI_DB_PORT="3306"
	elif [ "$MEDIAWIKI_DB_TYPE" = "postgres" ]; then
		MEDIAWIKI_DB_PORT="5432"
	fi
fi

export MEDIAWIKI_SITE_NAME MEDIAWIKI_DB_TYPE MEDIAWIKI_DB_HOST MEDIAWIKI_DB_USER MEDIAWIKI_DB_PASSWORD MEDIAWIKI_DB_NAME

TERM=dumb php -- <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

if ($_ENV['MEDIAWIKI_DB_TYPE'] == 'mysql') {

	$mysql = new mysqli($_ENV['MEDIAWIKI_DB_HOST'], $_ENV['MEDIAWIKI_DB_USER'], $_ENV['MEDIAWIKI_DB_PASSWORD'], '', (int) $_ENV['MEDIAWIKI_DB_PORT']);

	if ($mysql->connect_error) {
		file_put_contents('php://stderr', 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		exit(1);
	}

	if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($_ENV['MEDIAWIKI_DB_NAME']) . '`')) {
		file_put_contents('php://stderr', 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
		$mysql->close();
		exit(1);
	}

	$mysql->close();
}
EOPHP

if ! [ -e index.php -a -e includes/DefaultSettings.php ]; then
	echo >&2 "MediaWiki not found in $(pwd) - copying now..."

	if [ "$(ls -A)" ]; then
		echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
		( set -x; ls -A; sleep 10 )
	fi
	tar cf - --one-file-system -C /usr/src/mediawiki . | tar xf -
	echo >&2 "Complete! MediaWiki has been successfully copied to $(pwd)"
fi

: ${MEDIAWIKI_SHARED:=/data}
if [ -d "$MEDIAWIKI_SHARED" ]; then
	# If there is no LocalSettings.php but we have one under the shared
	# directory, symlink it
	if [ -e "$MEDIAWIKI_SHARED/LocalSettings.php" -a ! -e LocalSettings.php ]; then
		cp "$MEDIAWIKI_SHARED/LocalSettings.php" LocalSettings.php
		# We need to copy it, instead of symlink because file permisisons break
		# when trying to use Docker Machine
	fi

	# If the images directory only contains a README, then link it to
	# $MEDIAWIKI_SHARED/images, creating the shared directory if necessary
	if [ "$(ls images)" = "README" -a ! -L images ]; then
		rm -fr images
		mkdir -p "$MEDIAWIKI_SHARED/images"
		ln -s "$MEDIAWIKI_SHARED/images" images
	fi

	# If an extensions folder exists inside the shared directory, as long as
	# /var/www/html/extensions is not already a symbolic link, then replace it
	if [ -d "$MEDIAWIKI_SHARED/extensions" -a ! -h /var/www/html/extensions ]; then
		echo >&2 "Found 'extensions' folder in data volume, creating symbolic link."
	    rm -rf /var/www/html/extensions
	    ln -s "$MEDIAWIKI_SHARED/extensions" /var/www/html/extensions
	fi

	# If a skins folder exists inside the shared directory, as long as
	# /var/www/html/skins is not already a symbolic link, then replace it
	if [ -d "$MEDIAWIKI_SHARED/skins" -a ! -h /var/www/html/skins ]; then
		echo >&2 "Found 'skins' folder in data volume, creating symbolic link."
	    rm -rf /var/www/html/skins
	    ln -s "$MEDIAWIKI_SHARED/skins" /var/www/html/skins
	fi

	# If a composer.lock and composer.json file exist, use them to install
	# dependencies for MediaWiki and desired extensions, skins, etc.
	if [ -e "$MEDIAWIKI_SHARED/composer.lock" -a -e "$MEDIAWIKI_SHARED/composer.json" ]; then
		curl -sS https://getcomposer.org/installer | php
		cp "$MEDIAWIKI_SHARED/composer.lock" composer.lock
		cp "$MEDIAWIKI_SHARED/composer.json" composer.json
		php composer.phar install
	fi
fi

chown -R www-data: .

exec "$@"
