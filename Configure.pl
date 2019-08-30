#!/usr/bin/env perl
# Copyright (C) 2009-2019 The Perl Foundation

use 5.10.1;
use strict;
use warnings;
use Text::ParseWords;
use Getopt::Long;
use File::Spec;
use Cwd;
use FindBin;

BEGIN {
    if ( -d '.git' ) {
        my $set_config = !qx{git config rakudo.initialized};
        unless ( -e '3rdparty/nqp-configure/LICENSE' ) {
            print "Updating nqp-configure submodule...\n";
            my $msg =
    qx{git submodule sync --quiet 3rdparty/nqp-configure && git submodule --quiet update --init 3rdparty/nqp-configure 2>&1};
            if ( $? >> 8 == 0 ) {
                say "OK";
                $set_config = 1;
            }
            else {
                if ( $msg =~ /[']([^']+)[']\s+already exists and is not an empty/ )
                {
                    print "\n===SORRY=== ERROR: "
                      . "Cannot update submodule because directory exists and is not empty.\n"
                      . ">>> Please delete the following folder and try again:\n$1\n\n";
                    exit 1;
                }
            }
        }
        if ($set_config) {
            system("git config submodule.recurse true");
            system("git config rakudo.initialized 1");
        }
    }
}

use lib ( "$FindBin::Bin/tools/lib",
    "$FindBin::Bin/3rdparty/nqp-configure/lib" );
use NQP::Config qw<system_or_die slurp>;
use NQP::Config::Rakudo;

$| = 1;

my $cfg    = NQP::Config::Rakudo->new;
my $config = $cfg->config( no_ctx => 1 );
my $lang   = $cfg->cfg('lang');

# We don't use ExtUtils::Command in Configure.pl, but it is used in the Makefile
# Try `use`ing it here so users know if they need to install this module
# (not included with *every* Perl installation)
use ExtUtils::Command;
MAIN: {
    if ( -r 'config.default' ) {
        unshift @ARGV, shellwords( slurp('config.default') );
    }

    my $config_status = "$config->{lclang}_config_status";
    $config->{$config_status} = join ' ', map { qq("$_") } @ARGV;

    GetOptions(
        $cfg->options,      'help!',
        'prefix=s',         'libdir=s',
        'perl6-home=s',     'nqp-home=s',
        'sysroot=s',        'sdkroot=s',
        'relocatable',      'backends=s',
        'no-clean',         'with-nqp=s',
        'gen-nqp:s',        'gen-moar:s',
        'moar-option=s@',   'git-protocol=s',
        'ignore-errors',    'make-install!',
        'makefile-timing!', 'git-depth=s',
        'git-reference=s',  'github-user=s',
        'rakudo-repo=s',    'nqp-repo=s',
        'moar-repo=s',      'roast-repo=s',
        'expand=s',         'out=s',
        'set-var=s@',       'silent-build!'
      )
      or do {
        print_help();
        exit(1);
      };

    # Print help if it's requested
    if ( $cfg->opt('help') ) {
        print_help();
        exit(0);
    }
    if ( $cfg->opt('ignore-errors') ) {
        $cfg->note(
            "WARNING!",
            "Errors are being ignored.\n",
            "In the case of any errors the script may behave unexpectedly."
        );
    }

    $cfg->configure_paths;
    $cfg->configure_from_options;
    $cfg->configure_relocatability;
    $cfg->configure_repo_urls;
    $cfg->configure_commands;
    $cfg->configure_nqp;
    $cfg->configure_refine_vars;
    $cfg->configure_backends;
    $cfg->configure_misc;

    # Save options in config.status
    $cfg->save_config_status unless $cfg->has_option('expand');

    $cfg->options->{'gen-nqp'} ||= '' if $cfg->has_option('gen-moar');
    $cfg->gen_nqp;
    $cfg->configure_active_backends;

    $cfg->clean_old_p6_libs;

    $cfg->expand_template;

    unless ( $cfg->opt('expand') ) {
        my $make = $cfg->cfg('make');

        unless ( $cfg->opt('no-clean') ) {
            no warnings;
            print "Cleaning up ...\n";
            if ( open my $CLEAN, '-|', "$make clean" ) {
                my @slurp = <$CLEAN>;
                close($CLEAN);
            }
        }

        if ( $cfg->opt('make-install') ) {
            system_or_die($make);
            system_or_die( $make, 'install' );
            print "\n$lang has been built and installed.\n";
        }
        else {
            print "\nYou can now use '$make' to build $lang.\n";
            print "After that, '$make test' will run some tests and\n";
            print "'$make install' will install $lang.\n";
        }
    }

    exit 0;
}

#  Print some help text.
sub print_help {
    print <<"END";
Configure.pl - $lang Configure

General Options:
    --help             Show this text
    --prefix=<path>    Install files in dir; also look for executables there
    --libdir=<path>    Install architecture-specific files in dir; Perl6 modules
                       included
    --nqp-home=dir     Directory to install NQP files to
    --perl6-home=dir   Directory to install Perl 6 files to
    --relocatable
                       Dynamically locate NQP and Perl6 home dirs instead of
                       statically compiling them in. (On AIX and OpenBSD Rakudo
                       is always built non-relocatable, since both OSes miss a
                       necessary mechanism.)
    --sdkroot=<path>   When given, use for searching build tools here, e.g.
                       nqp, java, node etc.
    --sysroot=<path>   When given, use for searching runtime components here
    --backends=jvm,moar,js
                       Which backend(s) to use (or ALL for all of them)
    --gen-nqp[=branch]
                       Download, build, and install a copy of NQP before writing
                       the Makefile
    --gen-moar[=branch]
                       Download, build, and install a copy of MoarVM to use
                       before writing the Makefile
    --with-nqp=<path>
                       Provide path to already installed nqp
    --make-install     Install Rakudo after configuration is done
    --moar-option='--option=value'
                       Options to pass to MoarVM's Configure.pl
                       For example: --moar-option='--compiler=clang'
    --github-user=<user>
                       Fetch all repositories (rakudo, nqp, roast, MoarVM) from
                       this github user. Note that the user must have all
                       required repos forked from the originals.
    --rakudo-repo=<url>
    --nqp-repo=<url>
    --moar-repo=<url>
    --roast-repo=<url>
                       User-defined URL to fetch corresponding components
                       from. The URL will also be used to setup git push.
    --git-protocol={ssh,https,git}
                       Protocol used for cloning git repos
    --git-depth=<number>
                       Use the --git-depth option for git clone with parameter number
    --git-reference=<path>
                       Use --git-reference option to identify local path where git repositories are stored
                       For example: --git-reference=/home/user/repo/for_perl6
                       Folders 'nqp' and 'MoarVM' with corresponding git repos should be in for_perl6 folder
    --makefile-timing  Enable timing of individual makefile commands
    --no-clean         Skip cleanup before installation
    --ignore-errors    Ignore errors (such as the version of NQP)
    --expand=<template>
                       Expand template file. With this option Makefile is not
                       generated. The result is send to stdout unless --out
                       specified.
    --out=<file>       Filename to send output of --expand into.
    --set-var="config_variable=value"
                       Sets a config_variable to "value". Can be used multiple
                       times.
   --no-silent-build   Don't echo commands in Makefile target receipt.

Please note that the --gen-moar and --gen-nqp options are there for convenience
only and will actually immediately - at Configure time - compile and install
moar and nqp respectively. They will live under the path given to --prefix,
unless other targeting options are used. To configure how MoarVM should be
compiled, use the --moar-option flag and view MoarVM's Configure.pl for more
information on its configuration options.

Configure.pl also reads options from 'config.default' in the current directory.
END

    return;
}

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 4
#   fill-column: 100
# End:
# vim: expandtab shiftwidth=4:
