#!/usr/bin/perl
use strict;
use warnings;
# Local transport-only patch for the pinned 13.59 CLI. The upstream archive and
# every metadata parser/writer remain unchanged. A closed stdin pipe means its
# owner is gone; unlike a growing disk argfile, it can never receive more bytes.
my $path = shift @ARGV or die "Expected ExifTool path\n";
open my $in, '<', $path or die "$path: $!\n";
local $/;
my $text = <$in>;
close $in or die "$path: $!\n";
my $old = '        } elsif ($result == 0) {';
my $new = <<'REPLACEMENT';
        } elsif ($result == 0) {
            # PhotoTimezone transport patch: stdin EOF is final, not a disk argfile.
            if (defined $stayOpenFile and $stayOpenFile eq '-') {
                close STAYOPEN;
                $stayOpen = 0;
                last;
            }
REPLACEMENT
chomp $new;
my $count = ($text =~ s/\Q$old\E/$new/g);
$count == 1 or die "Unexpected upstream EOF layout ($count matches); refusing patch\n";
open my $out, '>', $path or die "$path: $!\n";
print {$out} $text or die "$path: $!\n";
close $out or die "$path: $!\n";
