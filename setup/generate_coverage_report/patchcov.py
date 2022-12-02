#!/usr/bin/python3

import coverage
import sqlite3
import sys
import re

patch_path = '/var/tmp/limeLib/coverage/patch.txt'
db_path = '/var/tmp/limeLib/coverage/.coverage'
fail_limit = 0

if len(sys.argv) >= 2:
    patch_path = sys.argv[1]

if len(sys.argv) >= 3:
    db_path = sys.argv[2]

if len(sys.argv) >= 4:
    fail_limit = int(sys.argv[3])

# coverage db schema described at
# https://coverage.readthedocs.io/en/latest/dbschema.html


# read patch from file
def read_patch(path):
    with open(path, 'r') as f:
        lines = f.readlines()
        f.close()
    return lines


def read_file_table(cursor):
    table = cursor.execute('SELECT * FROM file').fetchall()
    return table

def read_context_table(cursor):
    table = cursor.execute('SELECT * FROM context').fetchall()
    return table

def get_file_coverage(cursor, file_id):
    rows = cursor.execute("SELECT * FROM line_bits WHERE file_id = ?", (file_id, )).fetchall()
    rows2 = []
    for r in rows:
        rows2.append((r[0], r[1], coverage.numbits.numbits_to_nums(r[2])))
    return rows2


# returns filename ID for the record that matches the best requested filename
def find_best_filename_match(filename, table_files):
    for row in table_files:
        if row[1].endswith(filename):
            return row[0]
    return 0


def print_line(line, prefix=''):
    text_code_max_length = 7  # maximum length of test codes
    if len(prefix)>text_code_max_length:
        prefix = prefix[:text_code_max_length]+'+'
    format_str = '{0: <%s} {1}' % str(text_code_max_length+3)
    print(format_str.format(prefix, line))


# returns True with the line should be ignored
# e.g. it is a comment, closing parenthesis etc.
def should_ignore_line(line):
    # cut-off starting '+' character
    l = line[1:].strip()
    if not l:
        return True
    if l.startswith('#'):
        return True
    return False


def get_test_code(c):
    (q, r) = divmod(c, 26)
    a = chr(r+ord('A'))
    if q > 0:
        b = chr(q+ord('a')-1)
    else:
        b = ''
    return a+b

def get_patch_coverage(patch_path, db_path):

    patch_lines = read_patch(patch_path)

    # open db
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    table_files = read_file_table(cur)
    table_context = read_context_table(cur)

    # read patch line by line
    filename = ''
    skip_file = False
    line_no = 0
    code_lines_total = 0
    code_lines_covered = 0
    contexts_used = set()
    while patch_lines:

        line = patch_lines.pop(0).rstrip()
        
        # if this is a start of a new file
        if line.startswith('diff --git a/'):
            skip_file = False
            line_no = 0
            filename = line.split(' ')[2][2:]
            if filename.startswith('keylime/'):
                filename = filename[len('keylime'):]
            file_id = find_best_filename_match(filename, table_files)
            if file_id == 0 and filename.startswith('keylime/'): # nothing found
                # try searching again without the 'keylime' prefix
                file_id = find_best_filename_match(filename[len('keylime'):], table_files)
            print_line('\n'+line)

        # else if this is a /test/ file
        elif filename.startswith('test/') and (not skip_file):
            skip_file = True
            print_line('\nThis is a test file, ignoring...\n')

        # if this is a *.py file
        elif filename.endswith('.py') and (not skip_file):

            # if these are some diff parameters, print them
            if line.startswith('--- a/') or line.startswith('+++ b/') or line.startswith('index '):
                print_line(line)

            # indicator of patch start
            elif line.startswith('@@ '):
                line_no = int(re.sub(r'.*\+([0-9]+),.*', r'\1', line)) - 1
                print_line(line)

            # removed lines we just print
            elif line.startswith('-'):
                print_line(line)

            # these are either added/modified or untouched lines - both we want to present
            else:
                line_no += 1
                # if we should not ignore the line:
                if not should_ignore_line(line):
                    # but we do stats only for added/modified lines
                    if line.startswith('+'):
                        code_lines_total += 1
                    # find if the line has test coverage
                    line_coverage = get_file_coverage(cur, file_id)
                    contexts = [row[1] for row in line_coverage if line_no in row[2]]
                    # if there was a test coverage
                    if contexts:
                        if line.startswith('+'):
                            code_lines_covered += 1
                        contexts_used |= set(contexts)
                        prefix = ''.join([get_test_code(c) for c in contexts])
                    else:
                        prefix = '!'
                    print_line(line, prefix)

                # if the change should not be counted
                else:
                    print_line(line, '~')

        # write info that this file is skipped and enable skipping
        elif not skip_file:
            skip_file = True
            print_line('\nNot a *.py file, ignoring...\n')

    # print total coverage and legend
    print('-'*80)
    frac_coverage = 0 if code_lines_total == 0 else round(code_lines_covered*100/code_lines_total)
    print('Overall patch coverage: {} %, {} out of {} lines are covered by a test'.format(frac_coverage, code_lines_covered, code_lines_total))
    print('\nLegend:')
    print('  +  there are additional tests executing this line')
    print('  !  line not covered by a test')
    print('  ~  line is not being measured')
    for row in table_context:
        if row[0] in contexts_used:
            prefix = get_test_code(row[0])
            name = re.sub('^.*\/discover\/[^/]*\/tests', '', row[1])
            print('  {}  {}'.format(prefix, name))
    print()

    # close db
    con.close()

    return frac_coverage


v = get_patch_coverage(patch_path, db_path)

if v < fail_limit:
    print('FAIL: Code coverage is below the required limit {} %'.format(fail_limit))
    sys.exit(1)
