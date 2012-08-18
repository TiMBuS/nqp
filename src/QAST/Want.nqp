class QAST::Want is QAST::Node {
    method has_compile_time_value() {
        nqp::istype(self[0], QAST::Node)
            ?? self[0].has_compile_time_value()
            !! 0
    }
    
    method compile_time_value() {
        self[0].compile_time_value()
    }

    method evaluate_unquotes(@unquotes) {
        say('want');
        my $result := pir::repr_clone__PP(self);
        my $i := 0;
        my $elems := +@(self);
        while $i < $elems {
            $result[$i] := self[$i].evaluate_unquotes(@unquotes);
            $i := $i + 2;
        }
        $result
    }
}
