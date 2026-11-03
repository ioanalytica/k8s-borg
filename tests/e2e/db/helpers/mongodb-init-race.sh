# shellcheck shell=bash
#
# An init script for the mongo image (/docker-entrypoint-initdb.d), mounted
# into the MongoDB server `race` by run.sh: the server's first start fails
# the way docker-library/mongo#730 makes it fail, exit 48 "Address already in
# use", every time. A listener on 127.0.0.2:27017 sits next to the init's
# temporary mongod (127.0.0.1) and is in the way of the server (0.0.0.0).
# Perl returns once it listens and leaves a child holding the port until the
# container stops. The entrypoint runs init scripts in its init only, so the
# restart is left alone.
perl -MIO::Socket::INET -e '
  my $s = IO::Socket::INET->new(LocalAddr => "127.0.0.2", LocalPort => 27017, Listen => 1)
    or die "mongodb-init-race.sh: cannot listen on 127.0.0.2:27017: $!\n";
  exit if fork // die "mongodb-init-race.sh: fork: $!\n";
  sleep;'
