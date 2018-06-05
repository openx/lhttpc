REBAR := rebar3

.PHONY: all doc clean test dialyzer

all: compile doc

compile:
	$(REBAR) compile

doc:
	$(REBAR) edoc

test:
	$(REBAR) as test do xref,dialyzer,eunit,cover

release: all dialyzer test
	$(REBAR) release

clean:
	$(REBAR) clean
	rm -rf _build
