#!/usr/bin/env perl

use strict;
use warnings;
use Encode qw(encode_utf8);
use Plack::Request;
use Plack::Builder;
use Plack::Response;
use Search::Elasticsearch;
use HTML::Entities qw(encode_entities decode_entities);
use JSON::XS;

our ( $es, $Docs_Index, $Site_Index, $Tags_Index, $Max_Page, $Page_Size );

use FindBin;

BEGIN {
    chdir "$FindBin::RealBin/..";
    do "web/base.pl" or die $!;
}

our $JSON           = JSON::XS->new->utf8->pretty;
our $Remove_Host_RE = qr{^https?://[^/]+/guide/};
our $Referer_RE     = qr{
    ^
    (.+?)                           # book
    (?:/(current|master|\d[^/]+))?  # version
    /[^/]+                          # remainder
    $}x;

builder {
    mount '/search'  => \&search;
    mount '/suggest' => \&suggest;
};

#===================================
sub search {
#===================================
    my $q = _parse_request(@_)
        or return _as_json( 200, {} );

    my $request = _build_request(
        index     => _indices(),
        query     => _text_query( $q, _search_fields() ),
        highlight => _highlight($q),
        page      => $q->{page}
    );

    my $result = eval { $es->search($request) }
        or return _as_json( 500, { error => "$@" } );

    return _as_json( 200, _format_hits( $result->{hits}, $q->{page} ) );
}

#===================================
sub suggest {
#===================================
    my $q = _parse_request(@_)
        or return _as_json( 200, {} );

    my $result;

    eval {
        $result
            = !exists $q->{complete_tag} ? _suggest_hits($q)
            : length $q->{complete_tag}  ? _complete_tag($q)
            :                              _popular_tags($q);

    } or return _as_json( 500, { error => "$@" } );

    return _as_json( 200, $result );
}

#===================================
sub _suggest_hits {
#===================================
    my $q = shift;

    my $request = _build_request(
        index    => _indices(),
        query    => _text_query( $q, _suggest_fields() ),
        top_hits => _top_hits($q)
    );

    my $result = $es->search($request);
    if ( $result->{hits}{total} == 0 ) {
        $request = _build_request(
            index    => _indices(),
            query    => _text_query( $q, _search_fields() ),
            top_hits => _top_hits($q)
        );
        $result = $es->search($request);
    }
    my @hits;
    for my $bucket ( @{ $result->{aggregations}{sections}{buckets} } ) {
        push @hits, @{ $bucket->{top_hits_per_section}{hits}{hits} };
    }

    return _format_hits( { hits => \@hits, total => $result->{hits}{total} } );

}

#===================================
sub _complete_tag {
#===================================
    my $q = shift;

    return { suggestions => [] }
        if $q->{docs_version};

    my ($complete_context) = ( $q->{complete_tag} =~ m{(.*?)(?:/[^/]*)?$} );
    my @sections = ( $q->{context}, $complete_context );

    my $results = $es->suggest(
        index => $Tags_Index,
        body  => {
            text => $q->{complete_tag},
            tags => {
                completion => {
                    field   => 'suggest',
                    size    => 20,
                    context => { section => \@sections }
                }
            }
        }
    )->{tags}[0]{options};

    if ( my $product_tag = $q->{product} ) {
        @$results = grep { index( $_->{text}, $product_tag ) == 0 } @$results;
    }

    return _format_tags( $results, 'text' );

}

#===================================
sub _popular_tags {
#===================================
    my $q = shift;

    return { suggestions => [] }
        if $q->{docs_version};

    my $include = $q->{context} ? $q->{context} . '/[^/]*' : '[^/]*';
    my %filter = (
        exclude => { pattern => join '|', @{ $q->{tags} } },
        include => { pattern => $include }
    );

    my $request = _build_request(
        index    => _indices(),
        query    => _all_query($q),
        top_tags => _top_tags( $q, \%filter ),
    );

    my $results = $es->search($request);

    return _format_tags( $results->{aggregations}{tags}{buckets}, 'key' );
}

#===================================
sub _parse_request {
#===================================
    my $req = Plack::Request->new(@_);
    my $q = eval { $req->query_parameters->get_one('q') }
        or return;

    my $page = eval { $req->query_parameters->get_one('page') } || 1;
    $page = $Max_Page if $page > $Max_Page;

    my %query = ( page => $page );

    my $complete_tag = '';

    # final tag which requires completion
    if ( $q =~ s/(?:^|(?<=\s)):(\S*)$// ) {
        $complete_tag = $query{complete_tag} = $1;
        $complete_tag =~ s{^(^|/)[^/]+$}{};
    }

    # extract existing tags
    my @tags;
    while ( $q =~ s/(?:^|(?<=\s)):(\S+)// ) {
        push @tags, $1;
    }

    # query after stripping tags
    $query{q}    = $q;
    $query{tags} = \@tags;

    # return empty search unless we have one of these
    return unless $q =~ /\S/ || @tags || exists $query{complete_tag};

    # use tag with most slashes for suggest context
    my $longest     = 0;
    my $longest_tag = '';

    for ( @tags, $complete_tag ) {
        if ( my $slashes = $_ =~ tr{/}{} > $longest ) {
            $longest     = $slashes;
            $longest_tag = $_;
        }
    }

    $query{context} = $longest_tag;

    # do we have a docs version, or should we use 'current'
    if ( $longest_tag =~ m[Docs/.+/(?:\d|current|master)] ) {
        $query{has_doc_version} = 1;
    }
    return \%query;
}

#===================================
sub _indices {
#===================================
    return [ $Docs_Index, $Site_Index ];
}

#===================================
sub _search_fields {
#===================================
    return [
        "title^3",            "title.shingles^2",     "title.stemmed^2",
        'title.autocomplete', 'content',              'content.shingles',
        'content.stemmed',    'content.autocomplete', 'tags.autocomplete'
    ];
}

#===================================
sub _suggest_fields {
#===================================
    return [
        "title^2",            "title.shingles", "title.stemmed",
        'title.autocomplete', 'tags.autocomplete'
    ];
}

#===================================
sub _filters {
#===================================
    my $q = shift;

    my @filters = map { +{ term => { tags => $_ } } } @{ $q->{tags} };

    push @filters, { term => { is_current => \1 } }
        unless $q->{has_doc_version};

    return \@filters;
}

#===================================
sub _all_query {
#===================================
    my $q = shift;
    return { bool => { filter => _filters($q) } };
}

#===================================
sub _text_query {
#===================================
    my $q      = shift;
    my $fields = shift;
    return {
        function_score => {
            query => {
                bool => {
                    must => {
                        multi_match => {
                            type                 => 'cross_fields',
                            query                => $q->{q},
                            minimum_should_match => "0<95% 4<80%",
                            fields               => $fields
                        }
                    },
                    filter => _filters($q)
                }
            },
            functions => [
                {   filter => { term => { tags => 'Clients' } },
                    weight => 0.8
                },
                {   filter => { term => { tags => 'Elasticsearch' } },
                    weight => 1.1
                }
            ],
            score_mode => 'multiply'
        }
    };
}

#===================================
sub _highlight {
#===================================
    my $q = shift;
    $q =~ s/(^|\s):\S+//g;
    return {
        highlight => {
            pre_tags  => ['[[['],
            post_tags => [']]]'],
            fields    => { "content" => { number_of_fragments => 2, }, }
        }
    };
}

#===================================
sub _top_hits {
#===================================
    my $page = shift || 1;
    return {
        sections => {
            terms => {
                field => 'section',
                size  => 10,
                order => { max_score => 'desc' }
            },
            aggs => {
                top_hits_per_section => {
                    top_hits => {
                        sort => [
                            '_score',
                            {   "title.raw" => {
                                    order         => 'desc',
                                    missing       => '_last',
                                    unmapped_type => 'string'
                                }
                            }
                        ],
                        _source => [ 'title', 'section' ],
                        size    => 5
                    }
                },
                max_score => {
                    max => {
                        script => { inline => '_score', lang => 'expression' }
                    }
                }
            }
        },
    };
}

#===================================
sub _top_tags {
#===================================
    my ( $q, $filter ) = @_;

    return {
        tags => {
            terms => {
                field => 'tags',
                %$filter,
                size  => 100,
                order => { _term => 'asc' }
            }
        },
    };
}

#===================================
sub _build_request {
#===================================
    my %params = @_;

    my ( $from, $size ) = ( 0, 0 );
    unless ( $params{top_hits} ) {
        $size = $Page_Size;
        $from = ( ( $params{page} || 1 ) - 1 ) * $Page_Size;
    }

    return {
        index      => $params{index},
        preference => '_local',
        body       => {
            from    => $from,
            size    => $size,
            _source => [ 'title', 'section' ],
            query   => $params{query},
            aggs =>
                { %{ $params{top_hits} || {} }, %{ $params{top_tags} || {} } },
            %{ $params{highlight} || {} }
        }
    };
}

#===================================
sub _format_hits {
#===================================
    my $results = shift;
    my @hits;

    for ( @{ $results->{hits} } ) {
        my %hit = (
            data => {
                url     => $_->{_id},
                section => $_->{_source}{section} || ''
            },
            value => $_->{_source}{title}
        );
        if ( my $highlight = $_->{highlight}{"content"} ) {
            $hit{data}{highlight} = _format_highlights($highlight);
        }
        push @hits, \%hit;
    }
    my %response = ( suggestions => \@hits, total => $results->{total} );
    if ( my $page = shift ) {
        $response{total}     = $results->{total};
        $response{page}      = $page;
        $response{page_size} = $Page_Size;
        $response{max_page}  = $Max_Page;
    }
    return \%response;
}

#===================================
sub _format_tags {
#===================================
    my ( $results, $key ) = @_;

    my @hits;
    for (@$results) {
        my $tag = $_->{$key};
        $tag =~ s/ /-/g;
        push @hits, { value => $tag, data => { section => 'Tags' } };
    }
    return { suggestions => \@hits };
}

#===================================
sub _format_highlights {
#===================================
    my $highlights = shift;
    my @snippets;
    for my $snippet (@$highlights) {
        $snippet = encode_entities( $snippet, '<>&"' );
        $snippet =~ s/\[{3}/<em>/g;
        $snippet =~ s!\]{3}!</em>!g;
        $snippet =~ s/\s*\.\s*$//;
        push @snippets, $snippet;
    }
    return join " ... ", @snippets

}

#===================================
sub _as_json {
#===================================
    my ( $code, $data ) = @_;
    return [
        $code,
        [   'Content-Type'                => 'application/json',
            'Access-Control-Allow-Origin' => '*'
        ],
        [ $JSON->encode($data) ]
    ];
}

#===================================
sub _as_text {
#===================================
    my ( $code, $text ) = @_;
    return [
        $code,
        [   'Content-Type'                => 'text/plain',
            'Access-Control-Allow-Origin' => '*'
        ],
        [$text]
    ];
}

