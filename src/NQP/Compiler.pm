class NQP::Compiler is HLL::Compiler {
}

sub MAIN(@ARGS) {
    # Create and configure compiler object.
    my $nqpcomp := NQP::Compiler.new();
    $nqpcomp.language('nqp');
    $nqpcomp.parsegrammar(NQP::Grammar);
    $nqpcomp.parseactions(NQP::Actions);
    
    # Add extra command line options.
    my @clo := $nqpcomp.commandline_options();
    @clo.push('parsetrace');
    @clo.push('setting=s');
    
    # Enter the compiler.
    $nqpcomp.command_line(@ARGS, :encoding('utf8'), :transcode('ascii iso-8859-1'));
}
