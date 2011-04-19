#!/usr/bin/perl -w
use strict;

package PlugApps::Build::Database;
use DBI;
use Thread::Queue;
use Thread::Semaphore;
use Switch;
use File::stat;

# we only ever want one instance connected to the database.
# EVER.
our $available = Thread::Semaphore->new(1);

our ($q_svc, $q_db,$q_irc);

sub new{
    my ($class, $config) = @_;
    
    my $self = $config;
    $self->{dbh}=undef;
    
    bless $self, $class;
    return $self;
}


sub Run{
    my $self = shift;
    my $requests = -1;
    print "DbRun\n";
    my $open = $self->connect;
    ##
    while(my $orders = $q_db->dequeue ){
        my ($from,$order) = @{$orders};
        print "DB: got $order from $from\n";
        if($order eq "quit"){
            $available->down_force(10);
            last;
        }
        if( $order eq 'recycle'){
            last;
        }
        switch ($order) {
            case "count" { #generally recv'd from irc..
                my $table = @{$orders}[2];
                my $count = $self->count($table);
                $q_irc->enqueue(['db','count',$table,$count]);
            }
            case "percent_done" { #generally recv'd from irc..
                my $table = @{$orders}[2];
                my ($done,$count) = ($self->done(),$self->count('abs'));
                $q_irc->enqueue(['db','print',"Successful builds: ARMv5: $done->[0] of $count, ".sprintf("%0.2f%%",($done->[0]/$count)*100)." | ARMv7: $done->[1] of $count, ".sprintf("%0.2f%%",($done->[1]/$count)*100)]);
            }
            case "percent_failed" { #generally recv'd from irc..
                my $table = @{$orders}[2];
                my ($done,$count) = ($self->failed(),$self->count('abs'));
                $q_irc->enqueue(['db','print',"Failed builds: ARMv5: $done->[0] of $count, ".sprintf("%0.2f%%",($done->[0]/$count)*100)." | ARMv7: $done->[1] of $count, ".sprintf("%0.2f%%",($done->[1]/$count)*100)]);
            }
            case "next" { #generally recv'd from svc
                my ($arch, $builder) = split(/\|/, @{$orders}[2]);
                my $next = $self->get_next_package($builder, $arch);
                if( $next ){
                    my $pkg = join('-',@{$next}[0,1]).'!'.join(' ',@{$next}[2,3]);
                    printf("DbRespond:next:%s\n",$pkg);
                    $self->pkg_work(@{$next}[1], $builder, $arch);
                    $q_svc->enqueue(['db','next',@{$orders}[2],$pkg]);
                }else{
                    $q_svc->enqueue(['db','next',@{$orders}[2],'FAIL']);
                }
            }
            case "add" { # from svc
				my $pkg = @{$orders}[2];
            	if ($self->pkg_add($pkg)) {
            		$q_svc->enqueue(['db','add',$pkg,'FAIL']);
            	} else {
            		$q_svc->enqueue(['db','add',$pkg,'OK']);
            	}
            }
            case "unfail" { # from irc
				my ($arch, $package) = split(/ /, @{$orders}[2], 2);
            	$self->pkg_unfail($arch, $package);
            }
            case "done" { # from svc
            	$self->pkg_done(@{$orders}[2]);
            }
            case "fail" { # from svc
            	$self->pkg_fail(@{$orders}[2]);
            }
            case "unfuck" { # from irc
            	#$self->unfuck();
            	$q_irc->enqueue(['db', 'print', 'operation unfuck in progress, sir!']);
            }
            case "update" { # generally recv'd from irc
            	$self->update();
            	$q_irc->enqueue(['db', 'update', 'done']);
            }
			case "skip" { # from irc
				$self->pkg_skip(@{$orders}[2], 1);
			}
			case "unskip" { # from irc
				$self->pkg_skip(@{$orders}[2], 0);
			}
            case "rebuild" {
            	my $target = @{$orders}[2];
            	if ($target eq "all") {
            		$self->rebuild_all();
            	} elsif ($target eq "some") {
            		$self->rebuild_some();
            	} else {
            		$q_irc->enqueue(['db','print','Usage: !rebuild <all|some>']);
            	}
            }
			case "status" {
				my ($arch, $package) = split(/ /, @{$orders}[2], 2);
				$self->status($arch, $package);
			}
			case "ready" {
			my $target = @{$orders}[2];
			my ($detail,$which) = split(/\s/,$target);
			if( $target eq 'detail' || $detail eq 'detail'){
				my $ready = $self->ready_detail($which);
					$q_irc->enqueue(['db','print',sprintf("Packages waiting to be built: %d",$ready->[0])]);
				if( $ready->[0] > 1){
				$q_irc->enqueue(['db','print',sprintf("Packages waiting: %s",$ready->[1])]);
				}
			}else{
				my $ready = $self->ready();
				if( defined($ready->[0]) ){
					#$ready = $ready?$ready:"none";
					$q_irc->enqueue(['db','print',"Packages waiting to be built: ARMv5: $ready->[0], ARMv7: $ready->[1]"]);
				}else{
					$q_irc->enqueue(['db','print','ready: unknown error.']);
				}
			}
	    }
        }
    }
    ##
    $self->disconnect if $open;
    print "DbRunEnd\n";
    return $requests;
}

sub connect {
    my ($self) = @_;
    if( $available->down_nb ){
        my $database = $self->{mysql};
		my $user = $self->{user};
		my $pass = $self->{pass};
        my $db = DBI->connect("dbi:mysql:$database", "$user", "$pass", {RaiseError => 0, AutoCommit => 1});
        if( defined($db) ){
            # store our handle
            $self->{dbh} = $db;
            return 1;
        }else{
            # $db undef, failed
            $available->up;
        }
    }
    return undef;
}

sub disconnect {
    my ($self) = @_;
    if( defined($self->{dbh}) ){
        $self->{dbh}->disconnect;
        $available->up;
        $self->{dbh} = undef;
    }
}

sub get_next_package{
    my ($self, $builder, $arch) = @_;
    if( defined($self->{dbh}) ){
    	$self->{dbh}->do("update $arch set builder = null where builder = '$builder'");
        my $sql = "select
	p.repo, p.package, p.depends, p.makedepends
from
abs as p
join $arch as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
left outer join package_depends as dp on (p.id = dp.package)
left join $arch as d on (d.id = dp.dependency)
where p.skip = 0 and p.del = 0  
group by p.id
having (count(dp.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) ) order by p.importance limit 1";
        my $db = $self->{dbh};
        my @next_pkg = $db->selectrow_array($sql);
        return undef if (!$next_pkg[0]);
        return \@next_pkg;
    }else{
        return undef;
    }
}

sub ready{
    my $self = shift;
    
    if( defined($self->{dbh}) ){
        my $v5sql = "select count(*) from (
select
	p.repo, p.package, p.depends, p.makedepends
from
abs as p
join armv5 as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
left outer join package_depends as dp on (p.id = dp.package)
left join armv5 as d on (d.id = dp.dependency)
where p.skip = 0 and p.del = 0  
group by p.id
having (count(dp.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) )
) as xx";
        my $v7sql = "select count(*) from (
select
	p.repo, p.package, p.depends, p.makedepends
from
abs as p
join armv7 as a on (a.id = p.id and a.done = 0 and a.fail = 0 and a.builder is null)
left outer join package_depends as dp on (p.id = dp.package)
left join armv7 as d on (d.id = dp.dependency)
where p.skip = 0 and p.del = 0  
group by p.id
having (count(dp.id) = sum(d.done) or (p.depends = '' and p.makedepends = '' ) )
) as xx";
        my @next_pkg5 = $self->{dbh}->selectrow_array($v5sql);
        my @next_pkg7 = $self->{dbh}->selectrow_array($v7sql);
        return undef if (!defined($next_pkg5[0]) && !defined($next_pkg7[0]));
        return [$next_pkg5[0], $next_pkg7[0]];
    }else{
        return undef;
    }
}

sub ready_detail{
    my $self = shift;
    my $which = shift||5;
    
    $which = 'armv'.$which;
    if( defined($self->{dbh}) ){
        my $sql = "select
           p.repo, p.package, p.depends, p.makedepends
           from
           abs as p
            left outer join
             ( select 
                 dp.id, dp.package, d.done as 'done'
                 from package_depends dp
                 inner join $which as d on (d.id = dp.dependency)
             ) as dp on (p.id = dp.package)
            left outer join $which as a on (a.id = p.id)
            where p.skip = 0 and p.del = 0 and a.done = 0 and a.fail = 0 and a.builder is null group by p.id
            having (count(dp.id) = sum(dp.done) or (p.depends = '' and p.makedepends = '' ) ) order by p.importance ";
        my $sth = $self->{dbh}->prepare($sql);
        $sth->execute();
	my $res=undef;
	my $cnt=0;
	while( my $row = $sth->fetchrow_arrayref() ){
	    $res.=sprintf(" %s-%s,",$row->[0],$row->[1]);
	    $cnt++;
	}
	return [$cnt,$res];
    }else{
        return undef;
    }
}

sub count{
    my $self = shift;
    
    my $data = shift;
    print "DB-Count $data\n";
	my $ret = ($self->{dbh}->selectrow_array("select count(*) from $data"))[0] || 0;
    print "DB-Count $data : $ret\n";
    return $ret;
}

sub done{
    my $self = shift;
	my $armv5 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv5 on (armv5.id = abs.id) where done = 1 and fail = 0"))[0] || 0;
	my $armv7 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv7 on (armv7.id = abs.id) where done = 1 and fail = 0"))[0] || 0;
    return [$armv5, $armv7];
}

sub failed{
    my $self = shift;
	my $armv5 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv5 on (armv5.id = abs.id) where fail = 1"))[0] || 0;
	my $armv7 = ($self->{dbh}->selectrow_array("select count(*) from abs inner join armv7 on (armv7.id = abs.id) where fail = 1"))[0] || 0;
    return [$armv5, $armv7];
}

sub status{
    my ($self, $arch, $package) = @_;
	$arch = "armv$arch";
    if( defined($package)){
	if( $package ne ''){
	    my $sth = $self->{dbh}->prepare("select package, repo, done, fail, builder, git, abs, skip, del from abs inner join $arch as a on (abs.id = a.id) where package = ?");
	    $sth->execute($package);
	    my $ar = $sth->fetchall_arrayref();
	    if( scalar(@{$ar}) ){ # 1 or more
			foreach my $r (@{$ar}){
				my ($name, $repo, $done, $fail, $builder, $git, $abs, $skip, $del) = @{$r};
				my $state = (!$done && !$fail?'unbuilt':(!$done&&$fail?'failed':($done && !$fail?'done':'???')));
				if( $builder ne '' && $state eq 'unbuilt'){
					$state = 'building';
				}
				$state = "skipped" if ($skip);
				$state = "removed" if ($del);
				my $source = ($git&&!$abs?'git':(!$git&&$abs?'abs':'indeterminate'));
				my $status= sprintf("Status of package '%s' : repo=>%s, src=>%s, state=>%s",$name,$repo,$source,$state);
				$status .= sprintf(", builder=>%s",$builder) if $state eq 'building';
				my $blocklist = $self->{dbh}->selectall_arrayref("select abs.repo, abs.package, arm.fail, abs.skip, abs.del from package_name_provides as pn inner join package_depends as pd on (pn.package = pd.package) inner join $arch as arm on (pd.dependency = arm.id) inner join abs on (arm.id = abs.id) where arm.done = 0 and pn.name = ?", undef, $name);
				if ($blocklist) {
					$status .= ", blocked on: ";
					foreach my $blockrow (@$blocklist) {
						my ($blockrepo, $blockpkg, $blockfail, $blockskip, $blockdel) = @$blockrow;
						$status .= sprintf("%s/%s (%s) ", $blockrepo, $blockpkg, $blockdel?"D":$blockskip?"S":$blockfail?"F":"N");
					}
				}
				$q_irc->enqueue(['db','print',$status]);
			}
	    }else{ # zilch
			$q_irc->enqueue(['db','print','could not find package \''.$package.'\'']);
	    }
	}
    }
    
}

sub pkg_add {
	my ($self, $data) = @_;
	my ($arch, $repo, $package, $filename, $md5sum_sent) = split(/\|/, $data);
    print " -> adding $package\n";

    # verify md5sum
    my $md5sum_file = `md5sum $self->{packaging}->{in_pkg}/$filename`;
    if ($? >> 8) {
        print "    -> md5sum failed\n";
        return 1;
    }
    $md5sum_file = (split(/ /, $md5sum_file))[0];
    if ($md5sum_sent ne $md5sum_file) {
        print "    -> md5sum mismatch: $filename $md5sum_sent/$md5sum_file\n";
        return 1;
    }
    
    # move file, repo-add it
    print "   -> adding $arch/$repo/$package ($filename)..\n";
    system("mv -f $self->{packaging}->{in_pkg}/$filename $self->{packaging}->{repo}->{armv5}/$repo") if ($arch eq "armv5");
	system("mv -f $self->{packaging}->{in_pkg}/$filename $self->{packaging}->{repo}->{armv7}/$repo") if ($arch eq "armv7");
    if ($? >> 8) {
        print "    -> move failed\n";
        return 1;
    }
    system("$self->{packaging}->{archbin}/repo-add -q $self->{packaging}->{repo}->{armv5}/$repo/$repo.db.tar.gz $self->{packaging}->{repo}->{armv5}/$repo/$filename") if ($arch eq "armv5");
	system("$self->{packaging}->{archbin}/repo-add -q $self->{packaging}->{repo}->{armv7}/$repo/$repo.db.tar.gz $self->{packaging}->{repo}->{armv7}/$repo/$filename") if ($arch eq "armv7");
    if ($? >> 8) {
        print "    -> move failed\n";
        return 1;
    }
     
    return 0;
}

# assign builder to package
sub pkg_work {
	my ($self, $package, $builder, $arch) = @_;
	$self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.builder = ?, a.start = unix_timestamp() where abs.package = ?", undef, $builder, $package)
}

# set package done
sub pkg_done {
	my ($self, $data) = @_;
    my ($arch, $package) = split(/\|/, $data);
    $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.builder = null, a.done = 1, a.fail = 0, a.finish = unix_timestamp() where abs.package = ?", undef, $package);
}

# set package fail
sub pkg_fail {
	my ($self, $data) = @_;
    my ($arch, $package) = split(/\|/, $data);
    $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.builder = null, a.done = 0, a.fail = 1, a.finish = unix_timestamp() where abs.package = ?", undef, $package);
}

# unfail package or all
sub pkg_unfail {
	my ($self, $arch, $package) = @_;
	my $rows;
	$arch = "armv$arch";
	if ($package eq "all") {
		$rows = $self->{dbh}->do("update $arch set fail = 0, done = 0, builder = null where fail = 1");
	} else {
		$rows = $self->{dbh}->do("update $arch as a inner join abs on (a.id = abs.id) set a.fail = 0, a.done = 0, a.builder = null where abs.package = ?", undef, $package);
	}
	if ($rows < 1) {
		$q_irc->enqueue(['db','print',"Couldn't unfail $package for $arch"]);
	} else {
		$q_irc->enqueue(['db','print',"Unfailed $package for $arch"]);
	}
}

# modify package to be (un)skipped
sub pkg_skip {
	my ($self, $pkg, $op) = @_;
	my $rows = $self->{dbh}->do("update abs set skip = ? where package = ?", undef, $op, $pkg);
	if ($rows < 1) {
		$q_irc->enqueue(['db','print',"Couldn't modify $pkg, check the name."]);
	} else {
		$q_irc->enqueue(['db','print',sprintf("%s %s", $op?"Skipped":"Unskipped", $pkg)]);
	}
}


sub unfuck {
	my $self = shift;
	my $reporoot = $self->{packaging}->{repo}->{root};
	my $count = 0;
	
	my $rows = $self->{dbh}->selectall_arrayref("select repo, package, pkgname, pkgver, pkgrel from package where done = 0");
	
	foreach my $row (@$rows) {
		my ($repo, $package, $pkgname, $pkgver, $pkgrel) = @$row;
		my $namecount = () = split(/ /, $pkgname, -1);
		foreach my $name (split(/ /, $pkgname)) {
			my $namebase = "$reporoot/$repo/$name-$pkgver-$pkgrel";
			if (-e "$namebase-arm.pkg.tar.xz") {
				if (stat("$namebase-arm.pkg.tar.xz")->mtime gt "1295325270") {
					$namecount--;
				}
			} elsif (-e "$namebase-any.pkg.tar.xz") {
				if (stat("$namebase-any.pkg.tar.xz")->mtime gt "1295325270") {
					$namecount--;
				}
			} else {
				last;
			}
		}
		if ($namecount == 0) {
			$self->{dbh}->do("update package set fail = 0, done = 1 where package = '$package'");
			$count++;
		}
	}
	$q_irc->enqueue(['db', 'print', "unfucked $count packages"]);
}
		

sub update {
	my $self = shift;
	my (%gitlist, %abslist);
	my $gitroot = $self->{packaging}->{git}->{root};
	my $absroot = $self->{packaging}->{abs}->{root};
	my $workroot = $self->{packaging}->{workroot};
	my $archbin = $self->{packaging}->{archbin};

	$q_irc->enqueue(['db', 'print', 'Updating git..']);
	print "update git..\n";
	system("pushd $gitroot; git pull; popd");
	
	# add/update git packages
	print "update git packages..\n";
	my $git_count = 0;
	foreach my $repo (@{$self->{packaging}->{git}->{repos}}) {
		foreach my $pkg (glob("$gitroot/$repo/*")) {
			next unless (-d $pkg);
			$pkg =~ s/^\/.*\///;
			$gitlist{$pkg} = 1;
			my ($db_pkgver, $db_pkgrel, $db_plugrel) = $self->{dbh}->selectrow_array("select pkgver, pkgrel, plugrel from abs where package = ?", undef, $pkg);
			$db_plugrel = $db_plugrel || "0";
			my $vars = `./pkgsource.sh $gitroot $repo $pkg`;
			chomp($vars);
			my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends,$plugrel,$noautobuild) = split(/\|/, $vars);
			# no plugrel? no soup!
			next unless (defined $plugrel);
			# update abs table regardless of new version
			$self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, plugrel, depends, makedepends, git, abs, del) values (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, 0)
                              on duplicate key update repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, plugrel = ?, depends = ?, makedepends = ?, git = 1, abs = 0, del = 0",
							undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends, $repo, $pkgname, $provides, $pkgver, $pkgrel, $plugrel, $depends, $makedepends);
			# new package, different plugrel or version, done = 0
			next unless (! defined $db_pkgver || "$plugrel" ne "$db_plugrel" || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
			my $is_done = 0;
			# noautobuild set, assume built, done = 1
			$is_done = 1 if ($noautobuild);
			print "$repo/$pkg to $pkgver-$pkgrel-plug$plugrel, done = $is_done\n";
			# update architecture tables
			my ($db_id) = $self->{dbh}->selectrow_array("select id from abs where package = ?", undef, $pkg);
			$self->{dbh}->do("insert into armv5 (id, done, fail) values (?, ?, 0)
                              on duplicate key update done = ?, fail = 0",
							undef, $db_id, $is_done, $is_done);
			$self->{dbh}->do("insert into armv7 (id, done, fail) values (?, ?, 0)
                              on duplicate key update done = ?, fail = 0",
							undef, $db_id, $is_done, $is_done);
			# create work unit package
			`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$gitroot/$repo" "$pkg" > /dev/null`;
			$git_count++;
		}
	}
	
	# add/update abs packages
	$q_irc->enqueue(['db', 'print', 'Updating abs..']);
	print "update abs packages..\n";
	my $abs_count = 0;
	`ABSROOT=$absroot $archbin/abs`;
	foreach my $repo (@{$self->{packaging}->{abs}->{repos}}) {
		foreach my $pkg (glob("$absroot/$repo/*")) {
			next unless (-d $pkg);
			$pkg =~ s/^\/.*\///;
			#next if ($skiplist{$pkg});
			next if ($pkg =~ /.*\-lts$/);
			$abslist{$pkg} = 1;
			my ($db_pkgver, $db_pkgrel, $db_skip) = $self->{dbh}->selectrow_array("select pkgver, pkgrel, skip from abs where package = ?", undef, $pkg);
			my $vars = `./pkgsource.sh $absroot $repo $pkg`;
			chomp($vars);
			my ($pkgname,$provides,$pkgver,$pkgrel,$depends,$makedepends) = split(/\|/, $vars);
			if ($gitlist{$pkg}) {
				if ("$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel") {
					$q_irc->enqueue(['db','print',"$pkg is different in git, git = $db_pkgver-$db_pkgrel, abs = $pkgver-$pkgrel"]);
				}
				next;
			}
			# skip a bad source
			next if (! defined $pkgver);
			# create work unit here for non-skipped packages, to repackage abs changes without ver-rel bump
			if ($db_skip == 0) {
				`tar -zcf "$workroot/$repo-$pkg.tgz" -C "$absroot/$repo" "$pkg" > /dev/null`;
			}
			# update abs table
			my $is_skip = 0;
			$is_skip = 1 if ($db_skip);
			$self->{dbh}->do("insert into abs (package, repo, pkgname, provides, pkgver, pkgrel, depends, makedepends, git, abs, skip, del) values (?, ?, ?, ?, ?, ?, ?, ?, 0, 1, ?, 0)
                              on duplicate key update repo = ?, pkgname = ?, provides = ?, pkgver = ?, pkgrel = ?, depends = ?, makedepends = ?, git = 0, abs = 1, skip = ?, del = 0",
				undef, $pkg, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_skip, $repo, $pkgname, $provides, $pkgver, $pkgrel, $depends, $makedepends, $is_skip);
			# new package, different version, update, done = 0
			next unless (! defined $db_pkgver || "$pkgver-$pkgrel" ne "$db_pkgver-$db_pkgrel");
			print "$repo/$pkg to $pkgver-$pkgrel\n";
			# update architecture tables
			my ($db_id) = $self->{dbh}->selectrow_array("select id from abs where package = ?", undef, $pkg);
			$self->{dbh}->do("insert into armv5 (id, done, fail) values (?, 0, 0) on duplicate key update done = 0, fail = 0", undef, $db_id);
			$self->{dbh}->do("insert into armv7 (id, done, fail) values (?, 0, 0) on duplicate key update done = 0, fail = 0", undef, $db_id);
			$abs_count++;
		}
	}
	# prune git/abs in db
	my $rows = $self->{dbh}->selectall_arrayref("select package, git, abs from abs");
	foreach my $row (@$rows) {
		my ($pkg, $git, $abs) = @$row;
		next if ($git && $gitlist{$pkg});
		next if ($abs && $abslist{$pkg});
		print "del flag on $pkg\n";
		$self->{dbh}->do("update abs set del = 1 where package = ?", undef, $pkg);
	}
	
	# build package_name_provides
	$q_irc->enqueue(['db', 'update', "Updated $git_count from git, $abs_count from abs. Rebuilding depends.."]);
	print "building package_name_provides..\n";
	$rows = $self->{dbh}->selectall_arrayref("select id, pkgname, provides from abs where del = 0");
	$self->{dbh}->do("delete from package_name_provides");
	foreach my $row (@$rows) {
		my ($id, $pkgname, $provides) = @$row;
		foreach my $name (split(/ /, $pkgname)) {
			$name =~ s/(<|=|>).*//;
			$self->{dbh}->do("insert into package_name_provides (name, provides, package) values (?, 0, ?)", undef, $name, $id);
		}
		if ($provides ne "") {
			foreach my $name (split(/ /, $provides)) {
				$name =~ s/(<|=|>).*//;
				$self->{dbh}->do("insert into package_name_provides (name, provides, package) values (?, 1, ?)", undef, $name, $id);
			}
		}
	}
	
	$self->rebuild_all;
}

sub rebuild_all {
	my $self = shift;
	# build package_depends using depends AND makedepends
	$q_irc->enqueue(['db', 'print', "Rebuilding package_depends with depends and makedepends.."]);
	my $rows = $self->{dbh}->selectall_arrayref("select id, depends, makedepends from abs where del = 0");
	$self->{dbh}->do("delete from package_depends");
	foreach my $row (@$rows) {
		my ($id, $depends, $makedepends) = @$row;
		next if (!$depends && !$makedepends);
		$depends = "" unless $depends;
		$makedepends = "" unless $makedepends;
		my $statement = "insert into package_depends (dependency, package) select distinct package, $id from package_name_provides where name in (";
		foreach my $name (split(/ /, join(' ', $depends, $makedepends))) {
			$name =~ s/(<|=|>).*//;
			$statement .= "'$name', ";
		}
		$statement =~ s/, $/\)/;
		$self->{dbh}->do("$statement");
	}
	$q_irc->enqueue(['db', 'print', "Rebuild done."]);
}

sub rebuild_some {
	my $self = shift;
	# build package_depends using just depends
	$q_irc->enqueue(['db', 'print', "Rebuilding package_depends with only depends.."]);
	my $rows = $self->{dbh}->selectall_arrayref("select id, depends, makedepends from abs");
	$self->{dbh}->do("delete from package_depends");
	foreach my $row (@$rows) {
		my ($id, $depends, $makedepends) = @$row;
		next if (!$depends);
		$depends = "" unless $depends;
		$makedepends = "" unless $makedepends;
		my $statement = "insert into package_depends (dependency, package) select distinct package, $id from package_name_provides where name in (";
		foreach my $name (split(/ /, $depends)) {
			$name =~ s/(<|=|>).*//;
			$statement .= "'$name', ";
		}
		$statement =~ s/, $/\)/;
		$self->{dbh}->do("$statement");
	}
	$q_irc->enqueue(['db', 'print', "Rebuild done."]);
}

1;
