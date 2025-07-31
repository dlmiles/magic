#!/usr/bin/perl
#
#  This is filtering the system.map for the DSO generation to remove symbols
#  that do no exist in any object file.
#
#  Using a system.map asking to add version 'MAGIC_8.0' to missing symbols
#  causes 'ld' linking error on some platforms.
#
#  It is also useful to see what was found and not found to verbose can be
#  set as well,
#
#  Usage: perl filter_symbol_map.pl -v -q -v -v system.map system.map.in libabc.o libxyz.a
#
use strict;
use warnings;
use FileHandle;

my $verbose = 1; # 0..4

if(exists($ENV{CI}) and $ENV{CI} ne 'false') {
    # in CI be more verbose by default
    $verbose = 2 if($verbose == 1);
}

while(scalar(@ARGV) > 0) { # peekahead
    if($ARGV[0] eq '-q') {
        $verbose = 0;
        shift;
        next;
    }
    if($ARGV[0] eq '-v') {
        $verbose++;
        shift;
        next;
    }
    last;
}

my $outfname = '-';
my $tmpfname = "tmpfile$$.tmp";
my $fhl = \*STDERR; # logging
if(scalar(@ARGV) > 0) {
    $outfname = $ARGV[0];
    $tmpfname = $outfname . "$$.tmp";
    shift;
    $fhl = \*STDOUT if $outfname ne '-'; # when to file
}

my $infname = '-';
if(scalar(@ARGV) > 0) {
    $infname = $ARGV[0];
    shift;
    die "$0: $infname: $!" unless $infname eq '-' || -f $infname;
}

die "$0: $tmpfname: File already exists" if -f $tmpfname;

sub parse_line {
    my $line = $_[0];
    chomp $line;
    # *.map configuration lines
    return undef if($line =~ /{$/ || $line =~ /}\s*;$/);
    $line =~ s/^(\s*)global:(\s+)/$1$2/;
    if($line =~ /(\s+)(\S+)(;\s*)$/) {
        return undef if($2 eq '*'); # excluded symbol '*'
        return ($2, $1, $3);
    }
    undef;
};

# To allow input from stdin, we can only read it once
my @inlines = ();
my $fhi = FileHandle->new('<' . $infname) || die "$0: $infname: $!";
while(<$fhi>) {
    push(@inlines, $_);
}
close $fhi;

sub parse_infile {
    my ($infname, @args) = @_;
    my $datums = [];
    foreach (@inlines) {
        my ($symbol, $leader, $trailer) = &parse_line("" . $_ . "");
        if(defined($symbol)) {
            my $d = {
                'leader' => $leader,
                'symbol' => $symbol,
                'trailer' => $trailer,
            };
            #printf "%s	%s	%s\n", $1, $2, $3;
            push(@$datums, $d);
        }
    }
    $datums;
};

sub find_symbol {
    my ($datums, $sym) = @_;
    for my $d (@$datums) {
        # HASH is a thing too, input file order is preserved
        return $d if($d->{'symbol'} eq $sym);
    }
    undef;
};

# mark_symbols_found
sub process_object_like_file {
    my ($datums, $fname) = @_;
    my @cmdline = ('nm', $fname);
    open(my $fh, '-|', @cmdline) || die("$0: @cmdline: $!");
    while(<$fh>) {
        chomp;
        if(/^\S+ T (\S+)$/) { # filter .text T symbol types only
            my $sym = $1;
            my $found = &find_symbol($datums, $sym);
            printf $fhl "%s:%s = FOUND\n", $fname, $sym if defined($found) && $verbose > 3;
            if(defined($found)) {
                $found->{'found'} = 1;
                $found->{'fromfile'} = $fname;
            }
        }
    }
    close $fh || die "$0: close: $!";
    1;
};

my $datums = &parse_infile($infname);

# We expect objects/archives for 'nm' as next arguments
while(defined(my $fname = shift)) {
    next unless -f $fname; # skip non-existing
    process_object_like_file($datums, $fname);
    printf $fhl "%s\n", $fname if $verbose > 2;
}

my $sym_count_emitted = 0;
my $sym_count_removed = 0;
sub emit_outfile {
    my ($infile, $outfile, $datums) = @_;
    my $fho = FileHandle->new('>' . $tmpfname) || die "$0: $tmpfname: $!";

    foreach my $line (@inlines) {
        my $emit = 1;
        my ($sym) = parse_line($line);
        if(defined($sym)) {
            my $d = &find_symbol($datums, $sym);
            printf "# NOT DEFINED %s\n", $sym unless defined($d);
            $emit = 0 unless (defined($d) && $d->{'found'});
        }
        if($emit) {
            print $fho $line;
            $sym_count_emitted++ if(defined($sym));
        } else {
            $sym_count_removed++ if(defined($sym));
        }
    }

    close $fho || die "$0: close: $!";
    1;
};

&emit_outfile($infname, $tmpfname, $datums);

printf $fhl "# INPUTFILE: %s\n", $infname if $verbose > 2;
printf $fhl "# OUTPUTFILE: %s\n", $outfname if $verbose > 2;
#printf "# TMPFILE: %s\n", $tmpfname if $verbose > 2;

if($verbose > 1) {
    foreach my $d (@$datums) {
        my $s;
        $s = 'NOTFOUND';
        $s = '   FOUND' if $d->{'found'};
        my $fromfile;
        $fromfile = '';
        $fromfile = $d->{'fromfile'} if(defined($d->{'fromfile'}));
        printf "# %s: %s\t\t# %s\n", $s, $d->{'symbol'}, $fromfile;
    }
}

my $sym_count_total = scalar(@$datums);
my $sym_count_found = scalar(@$datums);
printf $fhl "%s: symbols %d total %d found, %d emitted, %d removed\n",
    $outfname, $sym_count_total, $sym_count_found, $sym_count_emitted, $sym_count_removed
    if $verbose;

# Transactionally update the target, we do this from Makefile/shell
#
# if test -f $outfname && cmp -s $outfname $tmpfile; then
#   rm -f $tmpfile
#   echo "system.map: No change, up-to-date"
# else
#   rm -f ${outfname}.old
#   ln -f $outfname ${outfname}.old  # best effort
#   mv -f $tmpfname $outfname
#   echo "system.map: Updated"
# fi

if($outfname eq '-') {
    my $fht = FileHandle->new('<' . $tmpfname) || die "$0: $tmpfname: $!";
    while(<$fht>) {
        print STDOUT $_;
    }
    close $fht;
} else {
    unless(rename $tmpfname, $outfname) {
        unlink $tmpfname;
        exit 1;
    }
}

# nm -D tclmagic.so | grep @MAGIC

exit 0;
