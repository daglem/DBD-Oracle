#!perl -w

sub ok ($$;$) {
    my($n, $ok, $warn) = @_;
    ++$t;
    die "sequence error, expected $n but actually $t"
    if $n and $n != $t;
    ($ok) ? print "ok $t\n"
	  : print "# failed test $t at line ".(caller)[2]."\nnot ok $t\n";
	if (!$ok && $warn) {
		$warn = $DBI::errstr || "(DBI::errstr undefined)" if $warn eq '1';
		warn "$warn\n";
	}
}

use strict;
use DBI qw(neat);
use DBD::Oracle qw(ORA_OCI);
use vars qw($tests);

unshift @INC ,'t';
require 'nchar_test_lib.pl';

$| = 1;
$^W = 1;

my $dbuser = $ENV{ORACLE_USERID} || 'scott/tiger';
my $dsn = oracle_test_dsn();
my $dbh = DBI->connect($dsn, $dbuser, '', {
	AutoCommit => 0,
	PrintError => 1,
	FetchHashKeyName => 'NAME_lc',
});

unless($dbh) {
	warn "Unable to connect to Oracle ($DBI::errstr)\nTests skipped.\n";
	print "1..0\n";
	exit 0;
}

eval {
    require Data::Dumper;
    $Data::Dumper::Useqq = $Data::Dumper::Useqq =1;
    $Data::Dumper::Terse = $Data::Dumper::Terse =1;
    $Data::Dumper::Indent= $Data::Dumper::Indent=1;
};

# XXX ought to extend test to check 'blank padded comparision semantics'
my @tests = ( # skip=1 to skip, ti=N to trace insert, ts=N to trace select
  { type=>97, name=>"CHARZ",    chops_space=>0, embed_nul=>0, skip=>1, ti=>8 },
  { type=> 5, name=>"STRING",   chops_space=>0, embed_nul=>0, skip=>1, ti=>8 },	# old Oraperl
  { type=>96, name=>"CHAR",     chops_space=>0, embed_nul=>1, skip=>0 },
  { type=> 1, name=>"VARCHAR2", chops_space=>1, embed_nul=>1, skip=>0 },	# current DBD::Oracle
#  { type=> 2, name=>"NVARCHAR2", chops_space=>1, embed_nul=>1, skip=>0 },	# LAB NVARCHAR nope not here
);

$tests = 3;
$_->{skip} or $tests+=8 for @tests;

print "1..$tests\n";

my ($sth,$tmp);
my $table = "dbd_ora__drop_me" . ($ENV{DBD_ORACLE_SEQ}||'');

# drop table but don't warn if not there
eval {
  local $dbh->{PrintError} = 0;
  $dbh->do("DROP TABLE $table");
};

ok(0, $dbh->do("CREATE TABLE $table (name VARCHAR2(2), vc VARCHAR2(20), c CHAR(20))"));

my $val_with_trailing_space = "trailing ";
my $val_with_embedded_nul = "embedded\0nul";

for my $test_info (@tests) {
  next if $test_info->{skip};

  my $ph_type = $test_info->{type} || die;
  my $name    = $test_info->{name} || die;
  print "#\n";
  print "# testing @{[ %$test_info ]} ...\n";
  print "#\n";
  if ($test_info->{skip}) {
    print "# skipping tests\n";
    foreach (1..12) { ok(0,1) }
    next;
  }

  $dbh->{ora_ph_type} =  $ph_type;
  ok(0, $dbh->{ora_ph_type} == $ph_type );

  $sth = $dbh->prepare("INSERT INTO $table(name,vc,c) VALUES (?,?,?)");
  $sth->trace($test_info->{ti}) if $test_info->{ti};
  $sth->execute("ts", $val_with_trailing_space, $val_with_trailing_space);
  $sth->execute("en", $val_with_embedded_nul,   $val_with_embedded_nul);
  $sth->execute("es", '', ''); # empty string
  $sth->trace(0) if $test_info->{ti};

  $dbh->trace($test_info->{ts}) if $test_info->{ts};
  $tmp = $dbh->selectall_hashref(qq{
	SELECT name, vc, length(vc) as len, nvl(vc,'ISNULL') as isnull, c
	FROM $table
  }, "name");
  ok(0, keys(%$tmp) == 3);
  $dbh->trace(0) if $test_info->{ts};
  $dbh->rollback;

  delete $_->{name} foreach values %$tmp;
  print Data::Dumper::Dumper($tmp);

  # check trailing_space behaviour
  my $expect = $val_with_trailing_space;
  $expect =~ s/\s+$// if $test_info->{chops_space};
  my $ok = ($tmp->{ts}->{vc} eq $expect);
  if (!$ok && $ph_type==1 && $name eq 'VARCHAR2') {
    warn " Placeholder behaviour for ora_type=1 (the default) varies with Oracle version.\n";
    warn " Oracle 7 didn't strip trailing spaces, Oracle 8 did, until 9.2.x\n";
    warn " Your system doesn't. If that seems odd, let us know.\n";
    $ok = 1;
  }
  ok(0, $ok, sprintf(" using ora_type %d expected %s but got %s for $name",
		$ph_type, neat($expect), neat($tmp->{ts}->{vc})) );

  # check embedded nul char behaviour
  $expect = $val_with_embedded_nul;
  $expect =~ s/\0.*// unless $test_info->{embed_nul};
  ok(0, $tmp->{en}->{vc} eq $expect, sprintf(" expected %s but got %s for $name",
		neat($expect),neat($tmp->{en}->{vc})) );

  # check empty string is NULL (irritating Oracle behaviour)
  ok(0, !defined $tmp->{es}->{vc});
  ok(0, !defined $tmp->{es}->{c});
  ok(0, !defined $tmp->{es}->{len});
  ok(0, $tmp->{es}->{isnull} eq 'ISNULL');

  exit 1 if $test_info->{ti} || $test_info->{ts};
}

ok(0, $dbh->do("DROP TABLE $table"));
ok(0, $dbh->disconnect );


__END__
