#!/usr/bin/perl -w
# SwiftOnSecurity Tweet UnDelete (@lnSecuritay)
# 3/23/16 chris_commat_misentropic_commercial
#
# https://twitter.com/SwiftOnSecurity/status/712456958637445122
# <@SwiftOnSecurity> @m0rb stop subtweeting me
#
# ...ok! >:3
use 5.10.1;
use warnings;
use strict;
use utf8;
use File::Slurp;
use Sereal::Decoder;
use Sereal::Encoder;
use Net::Twitter;
use AnyEvent::Twitter::Stream;
use Term::ANSIColor;
use Config::IniFiles;
use MIME::Base64;
use LWP::UserAgent;
use HTML::Entities;
binmode( STDOUT, ":utf8" );
################################################################
my $settings = Config::IniFiles->new( -file => "swift.ini" )
  or die "unable to open config";
my $ckey = $settings->val( 'twitter', 'ckey' ) or die "no consumer key";
my $csec = $settings->val( 'twitter', 'csec' ) or die "no consumer secret";
my $at   = $settings->val( 'twitter', 'at' )   or die;
my $asec = $settings->val( 'twitter', 'asec' ) or die;
################################################################
my $enc        = Sereal::Encoder->new( { compress => 1 } );
my $dec        = Sereal::Decoder->new();
my $hashfile   = "swift.sereal";
my $twet       = read_file($hashfile);
my $imgdir     = "/tmp";
my $tweets     = $dec->decode($twet) || ();
my $tweetcount = keys(%$tweets);
print colored( "[!] backlog loaded ($tweetcount)\n", 'green' );
my $nt = Net::Twitter->new(
    traits               => [qw/API::RESTv1_1/],
    consumer_key         => $ckey,
    consumer_secret      => $csec,
    access_token         => $at,
    access_token_secret  => $asec,
    decode_html_entities => '1',
    ssl                  => '1',
);
die unless $nt->authorized;
my $derp   = AE::cv;
my $stream = AnyEvent::Twitter::Stream->new(
    consumer_key    => $ckey,
    consumer_secret => $csec,
    token           => $at,
    token_secret    => $asec,
    method          => "filter",
    follow          => 2436389418,
    on_tweet        => sub {
        my $t     = shift;
        my $sn    = $t->{user}->{screen_name};
        my $tid   = $t->{id};
        my $msg   = $t->{text} or return 1;
        my $irt   = $t->{in_reply_to_status_id};
        my $taco  = $t->{entities}->{media}->[0]->{url};
        my $media = $t->{entities}->{media}->[0]->{media_url};
        my $vid =
          $t->{extended_entities}{media}[0]{video_info}{variants}[0]{url};

        if ( $sn eq "SwiftOnSecurity" ) {
            decode_entities($msg);
            print "$tid: <$sn> $msg\n";
            if ($taco) { $msg =~ s/$taco//g; }
            $tweets->{$tid}->{text} = $msg;
            if ($irt) {
                $tweets->{$tid}->{reply} = $irt;
            }
            if ($vid) {
                ( $tweets->{$tid}->{video}, $tweets->{$tid}->{alt} ) =
                  &fetch( $tid, $vid, "${imgdir}/${tid}.mp4" );
            }
            elsif ($media) {
                ( $tweets->{$tid}->{jpeg}, $tweets->{$tid}->{alt} ) =
                  &fetch( $tid, $media, "${imgdir}/${tid}.jpg" );
            }
            my $tash = $enc->encode($tweets);
            write_file( $hashfile, $tash );

        }
    },
    on_delete => sub {
        my ( $tid, $uid ) = @_;
        my $mid;
        if ( my $output = $tweets->{$tid} ) {
            print colored( "<TayBot> $output->{text}\n", 'red' );
            if ( $output->{video} ) {
                $mid =
                  &chunklet( "video/mp4", $output->{video}, $output->{alt} );
            }
            elsif ( $output->{jpeg} ) {
                $mid =
                  &chunklet( "image/jpeg", $output->{jpeg}, $output->{alt} );
            }
            my $update = { status => $output->{text} };
            if ( $output->{reply} ) {
                $update->{in_reply_to_status_id} = $output->{reply};
            }
            if ($mid) { $update->{media_ids} = $mid; }
            eval { $nt->update($update); };
        }
    },
);
$derp->recv;

sub fetch {
    my ( $tid, $media, $fn ) = @_;
    my $ua   = LWP::UserAgent->new;
    my $req  = HTTP::Request->new( GET => $media );
    my $resp = $ua->request($req);
    if ( $resp->is_success ) {
        write_file( $fn, $ua->request($req)->content );
    }
    my $alt = $nt->show_status(
        {
            id                   => $tid,
            include_entities     => 'true',
            include_ext_alt_text => 'true'
        }
    );
    if ( my $alt_text = $alt->{extended_entities}{media}[0]{ext_alt_text} ) {
        return ( $fn, $alt_text );
    }
    else {
        return ( $fn, undef );
    }
}

sub chunklet {
    die unless $nt->authorized;
    my ( $mt, $fn, $md ) = @_;
    my $fs   = -s $fn;
    my $si   = 0;
    my $init = $nt->upload(
        { command => 'INIT', media_type => $mt, total_bytes => $fs } )
      or die $@;
    my $media_id = $init->{media_id};
    open( IMAGE, $fn ) or die "!:$!\n";
    binmode IMAGE;

    while ( read( IMAGE, my $chunk, 1048576 ) ) {
        my $file = [
            undef, 'media',
            Content_Type => 'form-data',
            Content      => encode_base64($chunk)
        ];
        eval {
            $nt->upload(
                {
                    command       => 'APPEND',
                    media_id      => $media_id,
                    segment_index => $si,
                    media_data    => $file
                }
            );
        };
        $si += 1;
    }
    close(IMAGE);
    $nt->upload( { command => 'FINALIZE', media_id => $media_id } );
    if ($md) {
        $nt->create_media_metadata(
            { media_id => $media_id, alt_text => { text => $md } } );
    }

    return ($media_id);
}
