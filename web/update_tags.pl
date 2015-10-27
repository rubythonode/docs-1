#!/usr/bin/env perl

use strict;
use warnings;
use Search::Elasticsearch;
use JSON::XS;

our ( $es, $Tags_Index );
use FindBin;

BEGIN {
    chdir "$FindBin::RealBin/..";
    do "web/base.pl" or die $!;
}

use Proc::PID::File;
die "$0 already running\n" if Proc::PID::File->running( dir => '.run' );

our $alias = $Tags_Index;
our $indices = [ 'docs', 'site' ];

my $result = $es->indices->get_alias( index => $alias, ignore => 404 )
    or die "Index ($alias) doesn't exist\n";

my ($source) = keys %$result;
die "Index ($alias) does not exist\n" unless $source;
die "Index ($alias) is not associated with an alias\n"
    unless $result->{$source}{aliases};

my $index = create_index($alias);

my @seen;

my $bulk = $es->bulk_helper( index => $index, type => 'tag' );

while (1) {
    my $new = next_tags( \@seen );
    last unless @$new;

    for (@$new) {
        my ( $tag, $count ) = @{$_}{ 'key', 'doc_count' };

        my $section = $tag;
        $section=~s{(^|/)[^/]+$}{};

        $bulk->create_docs({section=>$section, suggest=>{input=>$tag,weight=>$count}});
        push @seen, $tag;
    }
}

$bulk->flush;
$es->indices->optimize( index => $index, max_num_segments => 1 );

print "\n";
switch_alias( $alias, $index );

#===================================
sub next_tags {
#===================================
    my $seen = shift;
    return $es->search(
        index => $indices,
        size  => 0,
        body  => {
            aggs => {
                tags => {
                    terms => {
                        size    => 200,
                        field   => 'tags',
                        exclude => $seen
                    }
                }
            }
        }
    )->{aggregations}{tags}{buckets};
}
