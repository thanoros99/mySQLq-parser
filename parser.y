%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

extern int  yylineno;
extern FILE *yyin;
void yyerror(const char *s);
int  yylex(void);

/* ================================================================
   Data types
   ================================================================ */

#define MAX_TABLES   64
#define MAX_COLS     64
#define MAX_QFROMS   16
#define MAX_DEFERRED 128

typedef enum { COL_INT = 0, COL_FLOAT = 1, COL_VARCHAR = 2 } ColType;

typedef struct {
    char    name[256];
    ColType type;
    int     vsize;   /* only for VARCHAR */
} ColDef;

typedef struct {
    char   name[256];
    ColDef cols[MAX_COLS];
    int    ncols;
} Table;

/* ================================================================
   Global symbol table (persists across statements)
   ================================================================ */

static Table g_tables[MAX_TABLES];
static int   g_ntables = 0;

/* ================================================================
   Per-statement state (reset for each statement)
   ================================================================ */

/* --- current CREATE TABLE being built --- */
static char   cr_name[256];
static ColDef cr_cols[MAX_COLS];
static int    cr_ncols;

/* --- current SELECT query context --- */
typedef struct {
    char tname[256];  /* actual table name   */
    char alias[256];  /* "" when no alias    */
} FromEntry;

static FromEntry q_froms[MAX_QFROMS];
static int       q_nfroms;
static int       q_has_alias;

/* Deferred SELECT column refs (checked after FROM/JOINs are known) */
typedef struct { char qual[256]; char col[256]; } ColRefD;
static ColRefD   q_sel_d[MAX_DEFERRED];
static int       q_sel_nd;
static int       q_sel_star;

/* Column type used when checking an IN / NOT IN list */
static ColType   in_col_type;

/* ================================================================
   Helper functions
   ================================================================ */

static void sem_error(const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "Semantic error at line %d: ", yylineno);
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fprintf(stderr, "\n");
    exit(1);
}

static Table *find_global_table(const char *name) {
    int i;
    for (i = 0; i < g_ntables; i++)
        if (strcmp(g_tables[i].name, name) == 0)
            return &g_tables[i];
    return NULL;
}

static ColDef *find_col_in_table(Table *t, const char *col) {
    int i;
    for (i = 0; i < t->ncols; i++)
        if (strcmp(t->cols[i].name, col) == 0)
            return &t->cols[i];
    return NULL;
}

/*
 * Resolve a name-or-alias to a Table in the current query.
 * When a table has an alias, it can ONLY be referenced by alias.
 * When a table has no alias, it is referenced by its actual name.
 */
static Table *resolve_query_table(const char *name_or_alias) {
    int i;
    for (i = 0; i < q_nfroms; i++) {
        if (q_froms[i].alias[0] != '\0') {
            /* table has an alias — only match by alias */
            if (strcmp(q_froms[i].alias, name_or_alias) == 0)
                return find_global_table(q_froms[i].tname);
        } else {
            /* no alias — match by table name */
            if (strcmp(q_froms[i].tname, name_or_alias) == 0)
                return find_global_table(q_froms[i].tname);
        }
    }
    return NULL;
}

/*
 * Immediately check a column reference against the current query context.
 * qual == "" means unqualified (just the column name).
 * Returns the ColDef* for type-checking, calls sem_error on failure.
 */
static ColDef *immediate_check_colref(const char *qual, const char *col) {
    Table  *t;
    ColDef *cd;

    if (qual[0] != '\0') {
        /* qualified: qual.col */
        t = resolve_query_table(qual);
        if (!t)
            sem_error("unknown table or alias '%s'", qual);
        cd = find_col_in_table(t, col);
        if (!cd)
            sem_error("column '%s' does not exist in table '%s'", col, t->name);
        return cd;
    }

    /* unqualified: col */
    if (q_has_alias)
        sem_error(
            "column '%s' must be written as alias.column when aliases are used",
            col);

    if (q_nfroms == 1) {
        t = find_global_table(q_froms[0].tname);
        if (!t) sem_error("internal: table '%s' not found", q_froms[0].tname);
        cd = find_col_in_table(t, col);
        if (!cd)
            sem_error("column '%s' does not exist in table '%s'", col, t->name);
        return cd;
    }

    /* multiple tables, no aliases: search all, reject if ambiguous */
    {
        int    found = 0;
        ColDef *result = NULL;
        int i;
        for (i = 0; i < q_nfroms; i++) {
            t = find_global_table(q_froms[i].tname);
            if (t) {
                cd = find_col_in_table(t, col);
                if (cd) { found++; result = cd; }
            }
        }
        if (found == 0)
            sem_error("column '%s' not found in any queried table", col);
        if (found > 1)
            sem_error("column '%s' is ambiguous (exists in multiple tables)", col);
        return result;
    }
}

static void deferred_add_selcol(const char *qual, const char *col) {
    if (q_sel_nd >= MAX_DEFERRED)
        sem_error("too many columns in SELECT list");
    strncpy(q_sel_d[q_sel_nd].qual, qual, 255);
    strncpy(q_sel_d[q_sel_nd].col,  col,  255);
    q_sel_nd++;
}

/* Check all deferred SELECT cols — called after FROM+JOINs are processed */
static void check_deferred_sel(void) {
    int i;
    if (q_sel_star) return;   /* SELECT * is always valid once table exists */
    for (i = 0; i < q_sel_nd; i++)
        immediate_check_colref(q_sel_d[i].qual, q_sel_d[i].col);
}

static void add_to_qfroms(const char *tname, const char *alias) {
    int i;
    if (q_nfroms >= MAX_QFROMS)
        sem_error("too many tables in a single query");

    if (alias[0] != '\0') {
        /* check alias does not shadow another alias or table name */
        for (i = 0; i < q_nfroms; i++) {
            if (strcmp(q_froms[i].alias, alias) == 0)
                sem_error("duplicate alias '%s'", alias);
        }
        q_has_alias = 1;
    }

    strncpy(q_froms[q_nfroms].tname, tname, 255);
    strncpy(q_froms[q_nfroms].alias, alias, 255);
    q_nfroms++;
}

static void init_select(void) {
    q_nfroms    = 0;
    q_has_alias = 0;
    q_sel_nd    = 0;
    q_sel_star  = 0;
}

/* Type compatibility:
   INT    column ← integer literal only
   FLOAT  column ← integer or float literal
   VARCHAR column ← string literal only               */
static int type_compat(ColType col_t, ColType val_t) {
    if (col_t == COL_INT     && val_t == COL_INT)     return 1;
    if (col_t == COL_FLOAT   && val_t == COL_INT)     return 1;
    if (col_t == COL_FLOAT   && val_t == COL_FLOAT)   return 1;
    if (col_t == COL_VARCHAR && val_t == COL_VARCHAR)  return 1;
    return 0;
}

static const char *coltype_name(ColType t) {
    if (t == COL_INT)     return "INT";
    if (t == COL_FLOAT)   return "FLOAT";
    if (t == COL_VARCHAR) return "VARCHAR";
    return "UNKNOWN";
}

%}

/* ================================================================
   Union and token declarations
   ================================================================ */

%union {
    int   ival;
    float fval;
    char *str;
    void *ptr;   /* ColDef* */
}

%token <str>  IDENTIFIER STRING_LIT
%token <ival> INTEGER
%token <fval> FLOAT_LIT

%token SELECT FROM WHERE LIMIT GROUP ORDER BY
%token IN AND OR NOT
%token CREATE TABLE INT_TYPE FLOAT_TYPE VARCHAR
%token JOIN ON AS
%token NE GE LE

/* col_ref returns ColDef* (as void*) for type-checking */
%type <ptr>  col_ref
/* value returns ColType as int */
%type <ival> value

/* Operator precedence (lowest → highest) */
%left  OR
%left  AND
%right NOT

%start program

%%

/* ================================================================
   Top-level
   ================================================================ */

program
    : statement_list
        { printf("Input is syntactically and semantically correct.\n"); }
    ;

statement_list
    : statement
    | statement_list statement
    ;

statement
    : create_stmt ';'
    | select_stmt ';'
    | error ';'
        { yyerrok; }
    ;

/* ================================================================
   CREATE TABLE
   ================================================================ */

create_stmt
    : CREATE TABLE IDENTIFIER
        {
            if (find_global_table($3))
                sem_error("table '%s' already exists", $3);
            strncpy(cr_name, $3, 255);
            cr_ncols = 0;
            free($3);
        }
      '(' col_def_list ')'
        {
            int i;
            if (g_ntables >= MAX_TABLES)
                sem_error("too many tables defined");
            strncpy(g_tables[g_ntables].name, cr_name, 255);
            for (i = 0; i < cr_ncols; i++)
                g_tables[g_ntables].cols[i] = cr_cols[i];
            g_tables[g_ntables].ncols = cr_ncols;
            g_ntables++;
        }
    ;

col_def_list
    : col_def
    | col_def_list ',' col_def
    ;

col_def
    : IDENTIFIER INT_TYPE
        {
            int i;
            for (i = 0; i < cr_ncols; i++)
                if (strcmp(cr_cols[i].name, $1) == 0)
                    sem_error("duplicate column '%s' in table '%s'", $1, cr_name);
            if (cr_ncols >= MAX_COLS) sem_error("too many columns");
            strncpy(cr_cols[cr_ncols].name, $1, 255);
            cr_cols[cr_ncols].type  = COL_INT;
            cr_cols[cr_ncols].vsize = 0;
            cr_ncols++;
            free($1);
        }
    | IDENTIFIER FLOAT_TYPE
        {
            int i;
            for (i = 0; i < cr_ncols; i++)
                if (strcmp(cr_cols[i].name, $1) == 0)
                    sem_error("duplicate column '%s' in table '%s'", $1, cr_name);
            if (cr_ncols >= MAX_COLS) sem_error("too many columns");
            strncpy(cr_cols[cr_ncols].name, $1, 255);
            cr_cols[cr_ncols].type  = COL_FLOAT;
            cr_cols[cr_ncols].vsize = 0;
            cr_ncols++;
            free($1);
        }
    | IDENTIFIER VARCHAR '(' INTEGER ')'
        {
            int i;
            if ($4 <= 0)
                sem_error("varchar size must be a strictly positive integer");
            for (i = 0; i < cr_ncols; i++)
                if (strcmp(cr_cols[i].name, $1) == 0)
                    sem_error("duplicate column '%s' in table '%s'", $1, cr_name);
            if (cr_ncols >= MAX_COLS) sem_error("too many columns");
            strncpy(cr_cols[cr_ncols].name, $1, 255);
            cr_cols[cr_ncols].type  = COL_VARCHAR;
            cr_cols[cr_ncols].vsize = $4;
            cr_ncols++;
            free($1);
        }
    ;

/* ================================================================
   SELECT
   ================================================================ */

select_stmt
    : SELECT
        { init_select(); }
      sel_col_ref_list
      FROM table_ref join_list
        { check_deferred_sel(); }
      opt_where opt_groupby opt_orderby opt_limit
    ;

/* ---- SELECT column list (deferred, before FROM is known) ---- */

sel_col_ref_list
    : '*'
        { q_sel_star = 1; }
    | sel_col_refs
    ;

sel_col_refs
    : sel_col_ref
    | sel_col_refs ',' sel_col_ref
    ;

sel_col_ref
    : IDENTIFIER
        { deferred_add_selcol("", $1); free($1); }
    | IDENTIFIER '.' IDENTIFIER
        { deferred_add_selcol($1, $3); free($1); free($3); }
    ;

/* ---- FROM clause ---- */

table_ref
    : IDENTIFIER
        {
            if (!find_global_table($1))
                sem_error("table '%s' has not been created", $1);
            add_to_qfroms($1, "");
            free($1);
        }
    | IDENTIFIER AS IDENTIFIER
        {
            if (!find_global_table($1))
                sem_error("table '%s' has not been created", $1);
            add_to_qfroms($1, $3);
            free($1); free($3);
        }
    ;

/* ---- JOIN clauses ---- */

join_list
    : /* empty */
    | join_list join_clause
    ;

/*
 * Mid-rule action adds the JOIN table to q_froms BEFORE the ON condition
 * is checked, so that the ON condition can reference it.
 */
join_clause
    : JOIN IDENTIFIER
        {
            if (!find_global_table($2))
                sem_error("table '%s' has not been created", $2);
            add_to_qfroms($2, "");
            free($2);
        }
      ON join_cond
    | JOIN IDENTIFIER AS IDENTIFIER
        {
            if (!find_global_table($2))
                sem_error("table '%s' has not been created", $2);
            add_to_qfroms($2, $4);
            free($2); free($4);
        }
      ON join_cond
    ;

/* ON condition: must be table_or_alias.col = table_or_alias.col */
join_cond
    : IDENTIFIER '.' IDENTIFIER '=' IDENTIFIER '.' IDENTIFIER
        {
            immediate_check_colref($1, $3);
            immediate_check_colref($5, $7);
            free($1); free($3); free($5); free($7);
        }
    ;

/* ---- Optional clauses (all use immediate col_ref check) ---- */

opt_where
    : /* empty */
    | WHERE condition
    ;

opt_groupby
    : /* empty */
    | GROUP BY col_ref_items
    ;

opt_orderby
    : /* empty */
    | ORDER BY col_ref_items
    ;

opt_limit
    : /* empty */
    | LIMIT INTEGER
        {
            if ($2 <= 0)
                sem_error("LIMIT value must be a strictly positive integer, got %d", $2);
        }
    ;

/* col_ref_items: non-empty list of immediately-checked column refs */
col_ref_items
    : col_ref
    | col_ref_items ',' col_ref
    ;

/* col_ref: immediately check against current query context */
col_ref
    : IDENTIFIER
        {
            $$ = (void *)immediate_check_colref("", $1);
            free($1);
        }
    | IDENTIFIER '.' IDENTIFIER
        {
            $$ = (void *)immediate_check_colref($1, $3);
            free($1); free($3);
        }
    ;

/* ================================================================
   WHERE conditions
   ================================================================ */

condition
    : simple_cond
    | condition AND condition
    | condition OR  condition
    | NOT condition
    | '(' condition ')'
    ;

simple_cond
    : col_ref '=' value
        {
            ColDef *cd = (ColDef *)$1;
            if (cd && !type_compat(cd->type, $3))
                sem_error(
                    "type mismatch in '=': column is %s, value is %s",
                    coltype_name(cd->type), coltype_name($3));
        }
    | col_ref NE value
        {
            ColDef *cd = (ColDef *)$1;
            if (cd && !type_compat(cd->type, $3))
                sem_error(
                    "type mismatch in '!=': column is %s, value is %s",
                    coltype_name(cd->type), coltype_name($3));
        }
    | col_ref '>' value
        {
            ColDef *cd = (ColDef *)$1;
            if (cd && !type_compat(cd->type, $3))
                sem_error(
                    "type mismatch in '>': column is %s, value is %s",
                    coltype_name(cd->type), coltype_name($3));
        }
    | col_ref '<' value
        {
            ColDef *cd = (ColDef *)$1;
            if (cd && !type_compat(cd->type, $3))
                sem_error(
                    "type mismatch in '<': column is %s, value is %s",
                    coltype_name(cd->type), coltype_name($3));
        }
    | col_ref GE value
        {
            ColDef *cd = (ColDef *)$1;
            if (cd && !type_compat(cd->type, $3))
                sem_error(
                    "type mismatch in '>=': column is %s, value is %s",
                    coltype_name(cd->type), coltype_name($3));
        }
    | col_ref LE value
        {
            ColDef *cd = (ColDef *)$1;
            if (cd && !type_compat(cd->type, $3))
                sem_error(
                    "type mismatch in '<=': column is %s, value is %s",
                    coltype_name(cd->type), coltype_name($3));
        }
    /* IN: mid-rule action captures column type BEFORE the value list */
    | col_ref IN
        { in_col_type = ($1 != NULL) ? ((ColDef *)$1)->type : COL_INT; }
      '(' in_value_list ')'
    | col_ref NOT IN
        { in_col_type = ($1 != NULL) ? ((ColDef *)$1)->type : COL_INT; }
      '(' in_value_list ')'
    ;

/* value: used in comparison operators, returns ColType */
value
    : INTEGER    { $$ = COL_INT;     }
    | FLOAT_LIT  { $$ = COL_FLOAT;   }
    | STRING_LIT { $$ = COL_VARCHAR; free($1); }
    ;

/* in_value_list: each item is checked against in_col_type */
in_value_list
    : in_value
    | in_value_list ',' in_value
    ;

in_value
    : INTEGER
        {
            if (!type_compat(in_col_type, COL_INT))
                sem_error(
                    "type mismatch in IN list: integer literal incompatible with %s column",
                    coltype_name(in_col_type));
        }
    | FLOAT_LIT
        {
            if (!type_compat(in_col_type, COL_FLOAT))
                sem_error(
                    "type mismatch in IN list: float literal incompatible with %s column",
                    coltype_name(in_col_type));
        }
    | STRING_LIT
        {
            if (!type_compat(in_col_type, COL_VARCHAR))
                sem_error(
                    "type mismatch in IN list: string literal incompatible with %s column",
                    coltype_name(in_col_type));
            free($1);
        }
    ;

%%

/* ================================================================
   yyerror and main
   ================================================================ */

void yyerror(const char *s) {
    fprintf(stderr, "Syntax error at line %d: %s\n", yylineno, s);
    exit(1);
}

static void print_file(const char *path) {
    FILE *f = fopen(path, "r");
    int   c;
    if (!f) return;
    printf("--- %s ---\n", path);
    while ((c = fgetc(f)) != EOF)
        putchar(c);
    printf("\n--- end of file ---\n\n");
    fclose(f);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <file.mysqlq>\n", argv[0]);
        return 1;
    }

    /* Always print the program first (required by spec) */
    print_file(argv[1]);
    fflush(stdout);

    yyin = fopen(argv[1], "r");
    if (!yyin) {
        fprintf(stderr, "Cannot open file: %s\n", argv[1]);
        return 1;
    }

    int ret = yyparse();
    fclose(yyin);
    return ret;
}
