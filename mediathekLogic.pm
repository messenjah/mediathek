#
#	mediathekLogic.pm
#Wed Feb  6 21:09:20 CET 2013

use MooseX::Declare;
use MooseX::NonMoose;
use MooseX::MarkAsMethods;

class My::Schema {
	use TempFileNames;
	use Set;
	use Data::Dumper;
	use POSIX qw(strftime mktime);
	use POSIX::strptime qw(strptime);
	use utf8;

	method greetings() {
		Log("Hello world");
	}

	method prune(Num $keepForDays = 10) {
		my $now = time();
		my $now_str = strftime("%Y-%m-%d %H:%M:%S", localtime($now));
		my $prune_str = strftime("%Y-%m-%d %H:%M:%S",
			localtime($now - $keepForDays * 86400));
		Log("Now: $now_str, pruning older than: $prune_str", 1);
		my $tv = $self->resultset('TvItem');
		my $tv_rs = $tv->search_rs({ date => { '<' => $prune_str } });
		Log('About to delete '. $tv_rs->count. ' items.', 1);
		$tv_rs->delete();
	}

	method serverList($c) {
		# today, yesterday
		#my ($td, $yd) = (
		#	strftime("%d_%m", localtime(time())), strftime("%d_%m", localtime(time() - 86400))
		#);
		my $serverList = main::meta_get([$c->{serverUrl}], "$c->{location}/servers.xml",
			refetchAfter => $c->{refreshServers});
		#my $servers = "cat $serverList | xml sel -T -t -m //URL -v . -n | grep -E '_$td|_$yd'";
		my @serverList = split(/\n/, `cat $serverList | xml sel -T -t -m //URL -v . -n`);
		Log('SeverList fetch: '. join("\n", @serverList), 5);
		# <b> seperate scanning due to faulty XML
		my @date = split(/\n/, `cat $serverList | xml sel -T -t -m //Datum -v . -n`);
		my @time = split(/\n/, `cat $serverList | xml sel -T -t -m //Zeit -v . -n`);
		my @prio = split(/\n/, `cat $serverList | xml sel -T -t -m //Prio -v . -n`);
		# determine order by decreasing time
		my @order = sort { $prio[$b] <=> $prio[$a]
			|| $date[$b] cmp $date[$a] || $time[$b] cmp $time[$a] } 0 .. $#serverList;
		Log('Serverorder: '. join(' ', @order), 5);
		@serverList = @serverList[@order];
		Log('Serverlist (ordered): '. join("\n", @serverList), 5);
		return @serverList;
	}

	method updateWithXml($c, $xml) {
		#
		# <p> xml parsing of new items
		#
		$self->prune($c->{keepForDays});
		my $sep = ':_:';
		my $cmd = 'cat '. qs($xml). ' | '
			.'bzcat | perl -pe "tr/\n/ /" | xml sel -T -t -m //X'
			." -v ./b -o $sep -v ./c -o $sep -v ./d -o $sep -v ./e -o $sep -v ./f -o $sep -v ./g -o $sep -v ./i -n";
		#
		# <p> database update
		#
		my @keys = ('channel', 'topic', 'title', 'day', 'time', 'url', 'command');
		my @dbkeys = ('channel', 'topic', 'title', 'date', 'url', 'command');
		my @skeys = ( 'channel', 'title' );	# search keys
		my $fh = IO::File->new("$cmd |");
		die "couldn't read '$xml'" if (!defined($fh));
		my @lines = map { substr($_, 0, -1) } (<$fh>);
		my $prev = {};
		my $i = 0;
		my $icnt = 0;	# insert count
		my $now = time();
		for my $l (@lines) {
			my $tv = $self->resultset('TvItem');
			if (!(++$i % 1e3)) {
				$self->resultset('TvItem')->clear_cache();
				Log(sprintf("%3.1eth entry", $i), 4);
			}
			my $this = makeHash(\@keys, [split(/$sep/, $l)]);
			# <p> field carry over
			$this->{channel} = $prev->{channel} if ($this->{channel} eq '');
			$this->{topic} = $prev->{topic} if ($this->{topic} eq '');
			$prev = $this;
			# <p> skip bogus entries
			next if ($this->{day} eq '' || $this->{time} eq '');
			$this->{date} = join('-', reverse(split(/\./, $this->{day}))). ' '. $this->{time};
			next if ($this->{date} eq ''
				|| $now - mktime(strptime($this->{date}, "%Y-%m-%d %H:%M:%S"))
				> $c->{keepForDays} * 86400);

			#my @items = $tv->search(makeHash(\@skeys, [@{$this}{@skeys}]));
			#print 'exists: '. @items. "\n";
			my $item = makeHash(\@dbkeys, [@{$this}{@dbkeys}]);
			#my $i = $tv->find_or_create($item, { key => 'channel_date_title_unique' });
			my $item0 = $tv->find_or_new($item, { key => 'channel_date_title_unique' });
			if (!$item0->in_storage) {
				$icnt++;
				$item0->insert;
			}
			#my $i = $tv->find($item, { key => 'channel_date_title_unique' });
			#print "Defined: ". defined($i). "\n";
			#$i = $tv->create(makeHash(\@dbkeys, [@{$this}{@dbkeys}])) if (!defined($i));
			#print $this->{title}, " ", $this->{channel}, " ", $this->{date}, "\n";
			#Log($i->id. " ".$i->title. " ". $i->channel. " ". $i->date, 6);
		}
		$fh->close();
		Log(sprintf('Added %d items.', $icnt), 3);
	}
	# <A> no proper quoting of csv output
	method update($c, $xml) {
		if (defined($xml)) {
			$self->updateWithXml($c, $xml);
		} else {
			my @serverList = $self->serverList($c);
			$self->updateWithXml($c, main::meta_get([$serverList[$i]], "$c->{location}/database_raw.xml_$i.bz2",
					refetchAfter => $c->{refreshTvitems}, seq => 1));
			for (my $i = 0; $i < $c->{refreshServersCount}; $i++) {
				$xml = main::meta_get([@serverList], "$c->{location}/database_raw.xml_$i.bz2",
					refetchAfter => $c->{refreshTvitems}, seq => 0);
				$self->updateWithXml($c, $xml);
			}
		}
	}

	method add_search($queries, $destination) {
		my $query = $self->resultset('TvGrep');
		for my $q (@$queries) { $query->create(
			{expression => $q, destination => $destination}
		); }
		return $query->all;
	}

	method delete_search($ids) {
		my $query = $self->resultset('TvGrep');
		for my $id (@$ids) { $query->search({id => $id})->delete(); }
		return $query->all;
	}

	method update_search($ids, $destination) {
		my $query = $self->resultset('TvGrep');
		for my $id (@$ids) { 
			$query->search({id => $id})->update({ destination => $destination });
		}
		return $query->all;
	}

	method search(@queries) {
		my $tv_item = $self->resultset('TvItem');
		my @r = map { my $query = $_;
			my %terms = map { /([^:]+):(.*)/, ($1, $2) } split(/;/, $query);
			my %query = map { my ($k, $v, $not) = ($_, $terms{$_});
				($not, $v) = ($v =~ m{^([!]?)(.*)}sog);
				($k, { ($not? 'not like': 'like'), $v })
			} keys %terms;
			main::Log(main::Dumper(\%query), 5);
			my @items = $tv_item->search(\%query);
			@items
		} @queries;
		return @r;
	}

	method fetch(Str $destination, @queries) {
		my @r = $self->search(@queries);
		for my $r (@r) {
			$r->fetchTo($destination);
		}
	}

	method auto_fetch(Str $destination) {
		if (!-e $destination) {
			Log(sprintf('VideoLibrary "%s" does not exist.', $destination), 4);
			return;
		}
		for my $q ( ($self->resultset('TvGrep')->all) ) {
			for my $r ( ($self->search($q->expression)) ) {
				my $record = $self->resultset('TvRecording')->find_or_new({ recording => $r->id },
					{ key => 'recording_unique' });
				if (!$record->in_storage()) {
					my $ret = $r->fetchTo($destination. '/'. $q->destination);
					$record->insert() if (!$ret);
					Log(sprintf('Recording success [%s]: %d', $r->title, $ret), 5);
				} else {
					Log(sprintf('Recording [%s] already recorded.', $r->title), 5);
				}
			}
		}
	}
}

class My::Schema::Result::TvItem {
	use TempFileNames;
	use Data::Dumper;
	use utf8;

	my %templates = (
		rmtp => 'flvstreamer --resume -r URL -o OUTPUT',
		http => 'mplayer URL -dumpstream -dumpfile OUTPUT'
	);
	method commandWithOutput(Str $destPath) {
		my ($protocol) = ($self->url() =~ m{^([^:]+)://}sog);
		my $command = mergeDictToString({
			URL => $self->url,
			OUTPUT => qs($destPath)
		}, $templates{$protocol});
		#my $command = $self->command();
		#$command = '-r '. $self->url() if (length($command) < 16);
		return $command;
	}

	# default format: day_title
	method fetchTo(Str $dest, Str $fmt = '%D_%T.%E') {
		my $destPath = $dest. '/'. mergeDictToString({
			'%T' => $self->title,
			'%D' => main::dateReformat($self->date, '%Y-%m-%d %H:%M:%S', '%Y-%m-%d'),
			'%E' => splitPathDict($self->url)->{extension}
		}, $fmt, { iterative => 'no' });
		Log("Fetching ". $self->title. " to ". $destPath, 1);
		Mkpath($dest, 5);

		return System($self->commandWithOutput($destPath), 2);
	}

	__PACKAGE__->meta->make_immutable(inline_constructor => 0);
}
