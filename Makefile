CC       = gcc
CFLAGS   = -Wall -g
FLEX     = /opt/homebrew/opt/flex/bin/flex
BISON    = /opt/homebrew/opt/bison/bin/bison
FLEX_LIB = /opt/homebrew/opt/flex/lib

all: myParser

myParser: lex.yy.c parser.tab.c parser.tab.h
	$(CC) $(CFLAGS) -o myParser lex.yy.c parser.tab.c -L$(FLEX_LIB) -lfl

parser.tab.c parser.tab.h: parser.y
	$(BISON) -d parser.y

lex.yy.c: lexer.l parser.tab.h
	$(FLEX) lexer.l

clean:
	rm -f lex.yy.c parser.tab.c parser.tab.h myParser
