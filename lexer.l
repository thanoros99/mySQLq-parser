%{
#include "parser.tab.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

static char kw_buf[512];

static const char *str_lower(const char *s) {
    size_t i;
    for (i = 0; s[i] && i < sizeof(kw_buf) - 1; i++)
        kw_buf[i] = tolower((unsigned char)s[i]);
    kw_buf[i] = '\0';
    return kw_buf;
}
%}

%option noyywrap
%option yylineno

DIGIT    [0-9]
ALPHA_   [a-zA-Z_]
ALNUM_   [a-zA-Z0-9_]

%%

[ \t\r\n]+              { /* skip whitespace */ }

"--"[^\n]*              { /* single-line comment */ }

"/*"                    {
                            int c, prev = 0;
                            while ((c = input()) != EOF) {
                                if (prev == '*' && c == '/') break;
                                prev = c;
                            }
                            if (c == EOF)
                                fprintf(stderr, "Warning: unterminated block comment\n");
                        }

{ALPHA_}{ALNUM_}*       {
                            const char *low = str_lower(yytext);
                            if (!strcmp(low, "select"))  return SELECT;
                            if (!strcmp(low, "from"))    return FROM;
                            if (!strcmp(low, "where"))   return WHERE;
                            if (!strcmp(low, "limit"))   return LIMIT;
                            if (!strcmp(low, "group"))   return GROUP;
                            if (!strcmp(low, "order"))   return ORDER;
                            if (!strcmp(low, "by"))      return BY;
                            if (!strcmp(low, "in"))      return IN;
                            if (!strcmp(low, "and"))     return AND;
                            if (!strcmp(low, "or"))      return OR;
                            if (!strcmp(low, "not"))     return NOT;
                            if (!strcmp(low, "create"))  return CREATE;
                            if (!strcmp(low, "table"))   return TABLE;
                            if (!strcmp(low, "int"))     return INT_TYPE;
                            if (!strcmp(low, "float"))   return FLOAT_TYPE;
                            if (!strcmp(low, "varchar")) return VARCHAR;
                            if (!strcmp(low, "join"))    return JOIN;
                            if (!strcmp(low, "on"))      return ON;
                            if (!strcmp(low, "as"))      return AS;
                            yylval.str = strdup(yytext);
                            return IDENTIFIER;
                        }

-?{DIGIT}+\.{DIGIT}+    { yylval.fval = atof(yytext); return FLOAT_LIT; }
-?{DIGIT}+              { yylval.ival = atoi(yytext); return INTEGER; }

\'[^\']*\'              { yylval.str = strdup(yytext); return STRING_LIT; }

"!="                    { return NE; }
">="                    { return GE; }
"<="                    { return LE; }
"="                     { return '='; }
">"                     { return '>'; }
"<"                     { return '<'; }
"*"                     { return '*'; }
"."                     { return '.'; }
";"                     { return ';'; }
","                     { return ','; }
"("                     { return '('; }
")"                     { return ')'; }

.                       {
                            fprintf(stderr,
                                "Lexical error at line %d: unknown character '%s'\n",
                                yylineno, yytext);
                        }

%%
