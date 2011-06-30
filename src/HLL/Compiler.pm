INIT {
    pir::load_bytecode('Parrot/Exception.pbc');
    my $file := pir::new('Env')<NQPEVENT>;
    if $file {
        my $fh := pir::new('FileHandle');
        $fh.open($file, 'w');
        pir::nqpevent_fh($fh);
    }
}

# This incorporates both the code that used to be in PCT::HLLCompiler as well
# as various additional things that initially appeared in the nqp-rx HLL::Compiler.
# Conversion of it all the NQP is a work in progress; for now, many methods are
# simply NQP wrappers around inline PIR.
class HLL::Compiler {
    has @!stages;
    has $!parsegrammar;
    has $!parseactions;
    has $!commandline_banner;
    has $!commandline_prompt;
    has @!cmdoptions;
    has $!usage;
    has $!compiler_progname;
    has $!language;
    has %!config;

    # This INIT serves as a cumulative "outer context" for code
    # executed in HLL::Compiler's interactive REPL.  It's invoked
    # exactly once upon load/init to obtain a context, and its
    # default LexPad is replaced with a Hash that we can use to
    # cumulatively store outer context information.  Both the
    # context and hash are then made available via package
    # variables.
    our $interactive_ctx;
    our %interactive_pad;
    our %parrot_config;
    INIT {
        # Set the context.
        $interactive_ctx := pir::getinterp__P(){'context'};
        
        # Set the pad, but transform it to a Hash first.
        my %pad_contents;
        %interactive_pad := pir::copy__0PP(
            pir::getattribute__PPs($interactive_ctx, 'lex_pad'),
            %pad_contents);
    }

    # XXX HACK!!! Need a Mu. :-)
    method new() {
        my $obj := pir::repr_instance_of__PP(self);
        $obj.BUILD();
        $obj
    }

    method BUILD() {
        # Default stages.
        @!stages     := pir::split(' ', 'parse past post pir evalpmc');
        
        # Command options and usage.
        @!cmdoptions := pir::split(' ', 'e=s help|h target=s dumper=s trace|t=s encoding=s output|o=s combine version|v show-config stagestats ll-backtrace');
        $!usage := "This compiler is based on HLL::Compler.\n\nOptions:\n";
        for @!cmdoptions {
            $!usage := $!usage ~ "    $_\n";
        }
        %parrot_config := pir::getinterp()[pir::const::IGLOBALS_CONFIG_HASH];
        %!config     := pir::new('Hash');
    }
    
    my sub value_type($value) {
        pir::isa($value, 'NameSpace')
            ?? 'namespace'
            !! (pir::isa($value, 'Sub') ?? 'sub' !! 'var')
    }
        
    method get_exports($module, :$tagset, *@symbols) {
        # convert a module name to something hash-like, if needed
        if (!pir::does($module, 'hash')) {
            $module := self.get_module($module);
        }

        $tagset := $tagset // (@symbols ?? 'ALL' !! 'DEFAULT');
        my %exports;
        my %source := $module{'EXPORT'}{~$tagset};
        if !pir::defined(%source) {
            %source := $tagset eq 'ALL' ?? $module !! {};
        }
        if @symbols {
            for @symbols {
                my $value := %source{~$_};
                %exports{value_type($value)}{$_} := $value;
            }
        }
        else {
            for %source {
                my $value := $_.value;
                %exports{value_type($value)}{$_.key} := $value;
            }
        }
        %exports;
    }

    method get_module($name) {
        my @name := self.parse_name($name);
        @name.unshift(pir::downcase($!language));
        pir::get_root_namespace__PP(@name);
    }

    method language($name?) {
        if $name {
            $!language := $name;
            pir::compreg__0sP($name, self);
        }
        $!language;
    }

    method compiler($name) {
        pir::compreg__Ps($name);
    }

    method config() { %!config };

    method load_module($name) {
        my $base := pir::join('/', self.parse_name($name));
        my $loaded := 0;
        try { pir::load_bytecode("$base.pbc"); $loaded := 1 };
        unless $loaded { pir::load_bytecode("$base.pir"); $loaded := 1 }
        self.get_module($name);
    }

    method import($target, %exports) {
        for %exports {
            my $type := $_.key;
            my %items := $_.value;
            if pir::can(self, "import_$type") {
                for %items { self."import_$type"($target, $_.key, $_.value); }
            }
            elsif pir::can($target, "add_$type") {
                for %items { $target."add_$type"($_.key, $_.value); }
            }
            else {
                for %items { $target{~$_.key} := $_.value; }
            }
        }
    }

    method autoprint($value) {
        nqp::say(~$value)
            unless (pir::getinterp__P()).stdout_handle().tell() > $*AUTOPRINTPOS;
    }

    method interactive(*%adverbs) {
        my $target := pir::downcase(%adverbs<target>);

        pir::print__vPS( pir::getinterp__P().stderr_handle(), self.commandline_banner );

        my $stdin    := pir::getinterp__P().stdin_handle();
        my $encoding := ~%adverbs<encoding>;
        if $encoding && $encoding ne 'fixed_8' {
            $stdin.encoding($encoding);
        }

        my $save_ctx;
        while 1 {
            last unless $stdin;

            my $prompt := self.commandline_prompt // '> ';
            my $code := $stdin.readline_interactive(~$prompt);

            last if pir::isnull($code);
            unless pir::defined($code) {
                nqp::print("\n");
                last;
            }

            # Set the current position of stdout for autoprinting control
            my $*AUTOPRINTPOS := (pir::getinterp__P()).stdout_handle().tell();
            my $*CTXSAVE := self;
            my $*MAIN_CTX;

            if $code {
                $code := $code ~ "\n";
                my $output;
                {
                    $output := self.eval($code, :outer_ctx($save_ctx), |%adverbs);
                    CATCH {
                        nqp::print(~$! ~ "\n");
                        next;
                    }
                };
                if pir::defined($*MAIN_CTX) {
                    our $interactive_ctx;
                    our %interactive_pad;
                    for $*MAIN_CTX.lexpad_full() {
                        %interactive_pad{$_.key} := $_.value;
                    }
                    $save_ctx := $interactive_ctx;
                }
                next if pir::isnull($output);

                if !$target {
                    self.autoprint($output);
                } elsif $target eq 'pir' {
                   nqp::say($output);
                } else {
                   self.dumper($output, $target, |%adverbs);
                }
            }
        }
    }

    method eval($code, *@args, *%adverbs) {
        my $output;
        $output := self.compile($code, |%adverbs);

        if !pir::isa($output, 'String')
                && %adverbs<target> eq '' {
            my $outer_ctx := %adverbs<outer_ctx>;
            if pir::defined($outer_ctx) {
                $output[0].set_outer_ctx($outer_ctx);
            }

            pir::trace(%adverbs<trace>);
            $output := $output(|@args);
            pir::trace(0);
        }

        $output;
    }

    method ctxsave() {
        $*MAIN_CTX :=
            Q:PIR {
                $P0 = getinterp
                %r = $P0['context';1]
            };
        $*CTXSAVE := 0;
    }

    method panic(*@args) {
        pir::die(pir::join('', @args))
    }

    method stages(@value?) {
        if +@value {
            @!stages := @value;
        }
        @!stages;
    }
    
    method parsegrammar(*@value) {
        if +@value {
            $!parsegrammar := @value[0];
        }
        $!parsegrammar;
    }

    method parseactions(*@value) {
        if +@value {
            $!parseactions := @value[0];
        }
        $!parseactions;
    }
    
    method commandline_banner($value?) {
        if pir::defined($value) {
            $!commandline_banner := $value;
        }
        $!commandline_banner;
    }
    
    method commandline_prompt($value?) {
        if pir::defined($value) {
            $!commandline_prompt := $value;
        }
        $!commandline_prompt;
    }
    
    method compiler_progname($value?) {
        if pir::defined($value) {
            $!compiler_progname := $value;
        }
        $!compiler_progname;
    }
    
    method commandline_options(@value?) {
        if +@value {
            @!cmdoptions := @value;
        }
        @!cmdoptions;
    }    

    method command_line(@args, *%adverbs) {
        ## this bizarre piece of code causes the compiler to
        ## immediately abort if it looks like it's being run
        ## from Perl's Test::Harness.  (Test::Harness versions 2.64
        ## from October 2006
        ## and earlier have a hardwired commandline option that is
        ## always passed to an initial run of the interpreter binary,
        ## whether you want it or not.)  We expect to remove this
        ## check eventually (or make it a lot smarter than it is here).
        if pir::index(@args[2], '@INC') >= 0 {
            pir::exit(0);
        }

        my $program-name := @args[0];
        my $res  := self.process_args(@args);
        my %opts := $res.options;
        my @a    := $res.arguments;

        for %opts -> $k {
            %adverbs{$k} := %opts{$k};
        }
        self.usage($program-name) if %adverbs<help>;
        self.version              if %adverbs<version>;
        self.show-config          if %adverbs<show-config>;

        pir::load_bytecode('dumper.pbc');
        pir::load_bytecode('PGE/Dumper.pbc');

        { # try
            my $result;
            if %adverbs<e> { $result := self.eval(%adverbs<e>, |@a, |%adverbs) }
            elsif !@a { $result := self.interactive(|%adverbs) }
            elsif %adverbs<combine> { $result := self.evalfiles(@a, |%adverbs) }
            else { $result := self.evalfiles(@a[0], |@a, |%adverbs) }

            if !pir::isnull($result) && %adverbs<target> eq 'pir' {
                my $output := %adverbs<output>;
                my $fh := ($output eq '' || $output eq '-')
                          ?? pir::getinterp__P().stdout_handle()
                          !! pir::new__Ps('FileHandle').open($output, 'w');
                self.panic("Cannot write to $output") unless $fh;
                pir::print($fh, $result);
                $fh.close()
            }
        }
    }

    method process_args(@args) {
        # First argument is the program name.
        self.compiler_progname(@args.shift);

        my $p := HLL::CommandLine::Parser.new(@!cmdoptions);
        $p.add-stopper('-e');
        $p.stop-after-first-arg;
        my $res;
        try {
            $res := $p.parse(@args);
            CATCH {
                nqp::say($_);
                self.usage;
                pir::exit(1);
            }
        }
        $res;
    }

    method evalfiles($files, *@args, *%adverbs) {
        my $target := pir::downcase(%adverbs<target>);
        my $encoding := %adverbs<encoding>;
        my @files := pir::does($files, 'array') ?? $files !! [$files];
        my @codes;
        for @files {
            my $in-handle := pir::new('FileHandle');
            my $err := 0;
            try {
                # the PIR version checked for utf8 specifically...
                # dunno why it was this way, and why it doesn't work in nqp
#                $in-handle.encoding($encoding) unless $encoding eq 'utf8';
                $in-handle.encoding($encoding);
                pir::push(@codes, $in-handle.readall($_));
                $in-handle.close;
                CATCH {
                    $err := "Error while reading from file: $_";
                }
            }
            pir::die($err) if $err;
        }
        my $code := pir::join('', @codes);
#            my $?FILES := pir::join(' ', @files);
        my $r := self.eval($code, |@args, |%adverbs);
        if $target eq '' || $target eq 'pir' {
            return $r;
        } else {
            return self.dumper($r, $target, |%adverbs);
        }
    }

    method compile($source, *%adverbs) {
        my %*COMPILING<%?OPTIONS> := %adverbs;

        my $target := pir::downcase(%adverbs<target>);
        my $result := $source;
        my $stderr := pir::getinterp().stderr_handle;
        for self.stages() {
            my $timestamp := pir::time__N();
            $result := self."$_"($result, |%adverbs);
            my $diff := pir::time__N() - $timestamp;
            if %adverbs<stagestats> {
                # TODO: plug in sprintf with %.3f
                $stderr.print__N("Stage $_: $diff\n");
            }
            last if $_ eq $target;
        }
        return $result;
    }

    method parse($source, *%adverbs) {
        my $s := $source;
        if %adverbs<transcode> {
            for pir::split(' ', %adverbs<transcode>) {
                try {
                    $s := pir::trans_encoding__ssi($s,
                            pir::find_encoding__is($_));
                }
            }
        }
        my $grammar := self.parsegrammar;
        my $actions;
        $actions    := self.parseactions unless %adverbs<target> eq 'parse';
        my $match   := $grammar.parse($s, p => 0, actions => $actions, rxtrace => %adverbs<rxtrace>);
        self.panic('Unable to parse source') unless $match;
        return $match;
    }

    method past($source, *%adverbs) {
        my $ast := $source.ast();
        self.panic("Unable to obtain ast from " ~ pir::typeof($source))
            unless $ast ~~ PAST::Node;
        $ast;
    }

    method post($source, *%adverbs) {
        pir::compreg__Ps('PAST').to_post($source, |%adverbs)
    }

    method pirbegin() {
        ".include 'cclass.pasm'\n"
        ~ ".include 'except_severity.pasm'\n"
        ~ ".include 'except_types.pasm'\n"
        ~ ".include 'iglobals.pasm'\n"
        ~ ".include 'interpinfo.pasm'\n"
        ~ ".include 'iterator.pasm'\n"
        ~ ".include 'sysinfo.pasm'\n"
        ~ ".include 'datatypes.pasm'\n"
    }
  
    method pir($source, *%adverbs) {
        self.pirbegin() ~ pir::compreg__Ps('POST').to_pir($source, |%adverbs)
    }

    method evalpmc($source, *%adverbs) {
        my $compiler := pir::compreg__Ps('PIR');
        $compiler($source)
    }

    method dumper($obj, $name, *%options) {
        if %options<dumper> {
            pir::load_bytecode('PCT/Dumper.pbc');
            my $dumper := PCT::Dumper{pir::downcase__SS(%options<dumper>)};
            $dumper($obj, $name)
        }
        else {
            _dumper($obj, $name)
        }
    }

    method usage($name?) {
        if $name {
            say($name);
        }
        nqp::say($!usage);
        pir::exit__vi(0);
    }

    method version() {
        my $version := %!config<version>;
        my $parver  := %parrot_config<VERSION>;
        my $parrev  := %parrot_config<git_describe> // '(unknown)';
        nqp::say("This is $!language version $version built on parrot $parver revision $parrev");
        pir::exit__vi(0);
    }

    method show-config() {
        for %parrot_config {
            nqp::say('parrot::' ~ $_.key ~ '=' ~ $_.value);
        }
        for %!config {
            nqp::say($!language ~ '::' ~ $_.key ~ '=' ~ $_.value);
        }
        pir::exit__vi(0);
    }

    method removestage($stagename) {
        my @new_stages := pir::new('ResizableStringArray');
        for @!stages {
            if $_ ne $stagename {
                @new_stages.push($_);
            }
        }
        @!stages := @new_stages;
    }

    method addstage($stagename, *%adverbs) {
        my $position;
        my $where;
        if %adverbs<before> {
            $where    := %adverbs<before>;
            $position := 'before';
        } elsif %adverbs<after> {
            $where    := %adverbs<after>;
            $position := 'after';
        } else {
            my @new-stages := pir::clone(self.stages);
            pir::push(@new-stages, $stagename);
            self.stages(@new-stages);
            return 1;
        }
        my @new-stages := pir::new('ResizableStringArray');
        for self.stages {
            if $_ eq $where {
                if $position eq 'before' {
                    pir::push(@new-stages, $stagename);
                    pir::push(@new-stages, $_);
                } else {
                    pir::push(@new-stages, $_);
                    pir::push(@new-stages, $stagename);
                }
            } else {
                pir::push(@new-stages, $_)
            }
        }
        self.stages(@new-stages);
    }

    method parse_name($name) {
        my @ns    := pir::split('::', $name);
        my $sigil := pir::substr(@ns[0], 0, 1);

        # move any leading sigil to the last item
        my $idx   := pir::index('$@%&', $sigil);
        if $idx >= 0 {
            @ns[0]  := pir::substr(@ns[0], 1);
            @ns[-1] := $sigil ~ @ns[-1];
        }

        # remove any empty items from the list
        # maybe replace with a grep() once we have the setting for sure
        my @actual_ns;
        for @ns {
            pir::push(@actual_ns, $_) unless $_ eq '';
        }
        @actual_ns;
    }

    method lineof($target, $pos, :$cache) {
        Q:PIR {
            .local pmc target, linepos
            .local int pos, cache
            target = find_lex '$target'
            $P0 = find_lex '$pos'
            pos = $P0
            $P0 = find_lex '$cache'
            cache = $P0

            # If we've previously cached C<linepos> for target, we use it.
            unless cache goto linepos_build
            linepos = getprop '!linepos', target
            unless null linepos goto linepos_done

            # calculate a new linepos array.
          linepos_build:
            linepos = new ['ResizableIntegerArray']
            unless cache goto linepos_build_1
            setprop target, '!linepos', linepos
          linepos_build_1:
            .local string s
            .local int jpos, eos
            s = target
            eos = length s
            jpos = 0
            # Search for all of the newline markers in C<target>.  When we
            # find one, mark the ending offset of the line in C<linepos>.
          linepos_loop:
            jpos = find_cclass .CCLASS_NEWLINE, s, jpos, eos
            unless jpos < eos goto linepos_done
            $I0 = ord s, jpos
            inc jpos
            push linepos, jpos
            # Treat \r\n as a single logical newline.
            if $I0 != 13 goto linepos_loop
            $I0 = ord s, jpos
            if $I0 != 10 goto linepos_loop
            inc jpos
            goto linepos_loop
          linepos_done:

            # We have C<linepos>, so now we search the array for the largest
            # element that is not greater than C<pos>.  The index of that
            # element is the line number to be returned.
            # (Potential optimization: use a binary search.)
            .local int line, count
            count = elements linepos
            line = 0
          line_loop:
            if line >= count goto line_done
            $I0 = linepos[line]
            if $I0 > pos goto line_done
            inc line
            goto line_loop
          line_done:
            .return (line)
        };
    }
}

my $compiler := HLL::Compiler.new();
$compiler.language('parrot');
