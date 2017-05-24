#!/usr/bin/perl

# @File geekerV2.pl
# @Author MrC0de
# @Created Aug 18, 2016 9:58:39 PM

# Use
use strict;
use warnings;
use geekerBotV2;

# Stuff
my $dbPass = shift || die("\n\nUsage: $0 <dbPass>\n");
$| = 1; #always remember to FLUSH

my $runBot = new geekerBotV2($dbPass);
$runBot->initDbTables();
while (1) {
    $runBot->run();
    select(undef,undef,undef,10); # 10s delay
}

