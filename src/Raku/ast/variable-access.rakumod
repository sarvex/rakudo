# Marker for different variable-like things.
class RakuAST::Var is RakuAST::Term {
}

# A typical lexical variable lookup (e.g. $foo).
class RakuAST::Var::Lexical is RakuAST::Var is RakuAST::Lookup {
    has str $.name;

    method new(str $name) {
        my $obj := nqp::create(self);
        nqp::bindattr_s($obj, RakuAST::Var::Lexical, '$!name', $name);
        $obj
    }

    method resolve-with(RakuAST::Resolver $resolver) {
        my $resolved := $resolver.resolve-lexical($!name);
        if $resolved {
            self.set-resolution($resolved);
        }
        Nil
    }

    method IMPL-TO-QAST(RakuAST::IMPL::QASTContext $context) {
        self.resolution.IMPL-LOOKUP-QAST($context)
    }
}

# A dynamic variable lookup (e.g. $*foo).
class RakuAST::Var::Dynamic is RakuAST::Var is RakuAST::Lookup {
    has str $.name;

    method new(str $name) {
        my $obj := nqp::create(self);
        nqp::bindattr_s($obj, RakuAST::Var::Dynamic, '$!name', $name);
        $obj
    }

    method needs-resolution() { False }

    method resolve-with(RakuAST::Resolver $resolver) {
        my $resolved := $resolver.resolve-lexical($!name, :current-scope-only);
        if $resolved {
            self.set-resolution($resolved);
        }
        Nil
    }

    method IMPL-TO-QAST(RakuAST::IMPL::QASTContext $context) {
        # If it's resolved in the current scope, just a lexical access.
        if self.is-resolved {
            my $name := self.resolution.lexical-name;
            QAST::Var.new( :$name, :scope<lexical> )
        }
        else {
            my $with-star := QAST::SVal.new( :value($!name) );
            my $without-star := QAST::SVal.new( :value(nqp::replace($!name, 1, 1, '')) );
            QAST::Op.new(
                :op('ifnull'),
                QAST::Op.new( :op('getlexdyn'), $with-star),
                QAST::Op.new(
                    :op('callstatic'), :name('&DYNAMIC-FALLBACK'),
                    $with-star, $without-star
                )
            )
        }
    }
}

# An attribute access (e.g. $!foo).
class RakuAST::Var::Attribute is RakuAST::Var is RakuAST::ImplicitLookups
                              is RakuAST::Attaching {
    has str $.name;
    has RakuAST::Package $!package;

    method new(str $name) {
        my $obj := nqp::create(self);
        nqp::bindattr_s($obj, RakuAST::Var::Attribute, '$!name', $name);
        $obj
    }

    method attach(RakuAST::Resolver $resolver) {
        my $package := $resolver.find-attach-target('package');
        if $package {
            # We can't check attributes exist until we compose the
            # package, since they may come from roles. Thus we need to
            # attach them to the package.
            $package.ATTACH-ATTRIBUTE-USAGE(self);
            nqp::bindattr(self, RakuAST::Var::Attribute, '$!package', $package);
        }
        else {
            # TODO check-time error
        }
    }

    method PRODUCE-IMPLICIT-LOOKUPS() {
        self.IMPL-WRAP-LIST([
            RakuAST::Term::Self.new,
        ])
    }

    method IMPL-TO-QAST(RakuAST::IMPL::QASTContext $context) {
        my @lookups := self.IMPL-UNWRAP-LIST(self.get-implicit-lookups);
        my $package := $!package.meta-object;
        my $attr-type := $package.HOW.get_attribute_for_usage($package, $!name).type;
        QAST::Var.new(
            :scope('attribute'), :name($!name), :returns($attr-type),
            @lookups[0].IMPL-TO-QAST($context),
            QAST::WVal.new( :value($package) ),
        )
    }
}

# A special compiler variable lookup, such as $?PACKAGE.
class RakuAST::Var::Compiler is RakuAST::Var is RakuAST::Lookup {
    has str $.name;

    method new(str $name) {
        my $obj := nqp::create(self);
        nqp::bindattr_s($obj, RakuAST::Var::Compiler, '$!name', $name);
        $obj
    }

    method resolve-with(RakuAST::Resolver $resolver) {
        my $resolved := $resolver.resolve-lexical($!name);
        if $resolved {
            self.set-resolution($resolved);
        }
        Nil
    }

    method IMPL-TO-QAST(RakuAST::IMPL::QASTContext $context) {
        self.resolution.IMPL-LOOKUP-QAST($context)
    }
}

# A regex positional capture variable (e.g. $0).
class RakuAST::Var::PositionalCapture is RakuAST::Var is RakuAST::ImplicitLookups {
    has Int $.index;

    method new(Int $index) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::Var::PositionalCapture, '$!index', $index);
        $obj
    }

    method PRODUCE-IMPLICIT-LOOKUPS() {
        self.IMPL-WRAP-LIST([
            RakuAST::Var::Lexical.new('&postcircumfix:<[ ]>'),
            RakuAST::Var::Lexical.new('$/'),
        ])
    }

    method IMPL-TO-QAST(RakuAST::IMPL::QASTContext $context) {
        my @lookups := self.IMPL-UNWRAP-LIST(self.get-implicit-lookups);
        my $index := $!index;
        $context.ensure-sc($index);
        QAST::Op.new(
            :op('call'),
            :name(@lookups[0].resolution.lexical-name),
            @lookups[1].IMPL-TO-QAST($context),
            QAST::WVal.new( :value($index) )
        )
    }
}

# A regex named capture variable (e.g. $<foo>).
class RakuAST::Var::NamedCapture is RakuAST::Var is RakuAST::ImplicitLookups {
    has RakuAST::QuotedString $.index;

    method new(RakuAST::QuotedString $index) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::Var::NamedCapture, '$!index', $index);
        $obj
    }

    method PRODUCE-IMPLICIT-LOOKUPS() {
        self.IMPL-WRAP-LIST([
            RakuAST::Var::Lexical.new('&postcircumfix:<{ }>'),
            RakuAST::Var::Lexical.new('$/'),
        ])
    }

    method IMPL-TO-QAST(RakuAST::IMPL::QASTContext $context) {
        my @lookups := self.IMPL-UNWRAP-LIST(self.get-implicit-lookups);
        my $op := QAST::Op.new(
            :op('call'),
            :name(@lookups[0].resolution.lexical-name),
            @lookups[1].IMPL-TO-QAST($context),
        );
        $op.push($!index.IMPL-TO-QAST($context)) unless $!index.is-empty-words;
        $op
    }

    method visit-children(Code $visitor) {
        $visitor($!index);
    }
}