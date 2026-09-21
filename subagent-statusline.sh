#!/bin/bash
# Claude Code subagent status line — one row per visible subagent.
#
# Replaces the default `name · description · token count` row. The point of the
# rewrite is the model: a delegation that should have gone to Opus but silently
# ran on the default model is invisible in the built-in row.
#
# stdin:  {..., columns, tasks:[{id,type,status,description,label,startTime,
#          model,effort,contextWindowSize,tokenCount,tokenSamples,cwd}]}
# stdout: one JSON object per row to override: {"id":..,"content":..}
#         Omit a task to keep its default row; emit "" to hide it.
#
# MEASURED against a real CC 2.1.278 payload — it differs from the docs:
#   - there is NO `name` field on a task, so the title falls back to the
#     description, then the label, then the type;
#   - `type` is the literal "local_agent", not the agent kind;
#   - `model` carries a "[1m]" suffix (claude-opus-5[1m]);
#   - `effort` is absent whenever the subagent inherits the session's effort,
#     which is the common case.
#
# Structure: exactly two child processes regardless of row count — one jq to
# extract and sanitise, one perl to measure, truncate and emit JSON. The bash
# loop in between forks nothing. Both matter: this runs on every refresh tick.

export LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

input=$(cat)
command -v jq >/dev/null 2>&1 || exit 0

RST=$'\033[0m'; DIM=$'\033[2m'
GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; MAG=$'\033[35m'

US=$'\x1f'

# Extraction + sanitisation happen together, in jq, because both failure modes
# they prevent are fatal to the whole stream rather than to one row:
#   - a non-integer reaching $(( )) aborts the subshell running the read loop,
#     so that row AND every row after it vanish with no visible error;
#   - a control char inside a field reaching the US-joined record either splits
#     it into a bogus extra row (newline) or shifts every later field by one
#     position (a literal US), which renders as plausible but wrong values.
# `tostring` first: a description that arrives as a number or an object makes
# gsub raise, and jq then abandons the rest of the array.
JQ_PROG='
  def clean: (. // "") | tostring | gsub("[\u0000-\u001f\u007f]"; " ");
  def whole: (. // 0) | if type == "number" and (isinfinite or isnan | not)
                        then (floor | if . < 0 then 0 else . end) else 0 end;
  ((.columns | whole) | (if . < 10 then 80 else . end) | tostring),
  (.tasks[]? | [
     (.id | clean),
     ((.name // .description // .type) | clean),
     (.status | clean),
     (.model | clean),
     (.effort | clean),
     (.tokenCount | whole | tostring),
     (.contextWindowSize | whole | tostring),
     (.startTime | whole | tostring),
     (.label | clean),
     (.type | clean)
   ] | join("\u001f"))
'
# Read with a loop, not `mapfile`: macOS ships bash 3.2 as /bin/bash and
# `mapfile` is a bash 4 builtin, so it fails with "command not found" there and
# takes the whole status line with it.
RECORDS=()
while IFS= read -r _line; do
  RECORDS+=("$_line")
done < <(jq -r "$JQ_PROG" <<<"$input" 2>/dev/null)
[ "${#RECORDS[@]}" -eq 0 ] && exit 0

COLS=${RECORDS[0]}
NOW=$(date +%s)

# Model family -> short label + colour, keyed on the resolved model id so a new
# dated snapshot of a known family still matches. The "[1m]" suffix is surfaced,
# not swallowed: a teammate on the 1M context window costs very differently.
model_label() {
  local id=$1 ctx="" name=""
  case "$id" in *"[1m]"*) ctx="${DIM}·1M${RST}" ;; esac
  case "$id" in
    *opus*)   name="${MAG}Opus${RST}" ;;
    *fable*)  name="${MAG}Fable${RST}" ;;
    *mythos*) name="${MAG}Mythos${RST}" ;;
    *sonnet*) name="${CYN}Sonnet${RST}" ;;
    *haiku*)  name="${DIM}Haiku${RST}" ;;
    "")       printf '' ; return ;;
    *)        name="${DIM}${id%%-2*}${RST}" ;;
  esac
  printf '%s%s' "$name" "$ctx"
}

# Effort is either a level name or a raw token budget.
effort_label() {
  case "$1" in
    "")     printf '' ;;
    low)    printf 'l' ;;
    medium) printf 'm' ;;
    high)   printf 'h' ;;
    xhigh)  printf 'X' ;;
    max)    printf 'M' ;;
    *)      printf '%s' "$1" ;;
  esac
}

status_mark() {
  case "$1" in
    running|in_progress) printf '%s' "${GRN}▸${RST}" ;;
    completed|done)      printf '%s' "${DIM}✓${RST}" ;;
    failed|error)        printf '%s' "${RED}✗${RST}" ;;
    *)                   printf '%s' "${DIM}·${RST}" ;;
  esac
}

fmt_tok() {
  local t=$1
  if   [ "$t" -ge 1000000 ]; then printf '%d.%dM' $(( t / 1000000 )) $(( t % 1000000 / 100000 ))
  elif [ "$t" -ge 1000 ];    then printf '%d.%dK' $(( t / 1000 ))    $(( t % 1000 / 100 ))
  else printf '%s' "$t"
  fi
}

# startTime measured as epoch millis on 2.1.278. The threshold is far from both
# interpretations' plausible ranges: as seconds it lands in the year 5138, as
# millis it reaches back to 1973.
fmt_elapsed() {
  local st=$1 sec
  [ "$st" -eq 0 ] && { printf ''; return; }
  if [ "$st" -gt 100000000000 ]; then sec=$(( NOW - st / 1000 )); else sec=$(( NOW - st )); fi
  [ "$sec" -lt 0 ] && { printf ''; return; }
  if   [ "$sec" -lt 60 ];   then printf '%ds' "$sec"
  elif [ "$sec" -lt 3600 ]; then printf '%dm%ds' $(( sec / 60 )) $(( sec % 60 ))
  else printf '%dh%dm' $(( sec / 3600 )) $(( sec % 3600 / 60 ))
  fi
}

ROWS=()
for (( r = 1; r < ${#RECORDS[@]}; r++ )); do
  IFS=$US read -r id title status model effort tokens ctxsize start label type <<<"${RECORDS[r]}"
  [ -z "$id" ] && continue

  row="$(status_mark "$status") ${title}"

  # `type` is the execution kind (local_agent, local_bash, local_workflow,
  # remote_agent, in_process_teammate), not the agent flavour. local_agent is the
  # overwhelming default, so only the others are worth a column.
  case "$type" in
    local_agent|"") : ;;
    remote_agent)       row="${row} ${DIM}☁${RST}" ;;
    local_bash)         row="${row} ${DIM}\$${RST}" ;;
    local_workflow)     row="${row} ${DIM}⚙${RST}" ;;
    in_process_teammate) row="${row} ${DIM}@${RST}" ;;
    *)                  row="${row} ${DIM}${type}${RST}" ;;
  esac

  m=$(model_label "$model")
  e=$(effort_label "$effort")
  if [ -n "$m" ]; then
    row="${row} ${DIM}·${RST}${m}"
    [ -n "$e" ] && row="${row}${DIM}·${e}${RST}"
  elif [ -n "$e" ]; then
    row="${row} ${DIM}·${e}${RST}"
  fi

  # Token count against this task's own context window, so the percentage means
  # the same thing on a 200k model and on a 1M one.
  if [ "$tokens" -gt 0 ]; then
    tokseg="$(fmt_tok "$tokens")"
    if [ "$ctxsize" -gt 0 ]; then
      pct=$(( tokens * 100 / ctxsize ))
      if   [ "$pct" -ge 80 ]; then tokseg="${RED}${tokseg} ${pct}%${RST}"
      elif [ "$pct" -ge 50 ]; then tokseg="${YLW}${tokseg} ${pct}%${RST}"
      else tokseg="${DIM}${tokseg} ${pct}%${RST}"
      fi
    else
      tokseg="${DIM}${tokseg}${RST}"
    fi
    row="${row} ${DIM}·${RST}${tokseg}"
  fi

  el=$(fmt_elapsed "$start")
  [ -n "$el" ] && row="${row} ${DIM}·${el}${RST}"

  # `label` is the live activity line — it changes every tick ("Reading the spec
  # section", "Measuring CJK overflow"), while `description` is the static task
  # brief the caller wrote. The obvious `.description // .label` never reaches
  # label at all, because description is always populated and jq's `//` treats
  # any string as truthy. Showing label instead, when it says something the
  # title does not, is the whole reason this row beats the default one.
  tail_seg=""
  [ -n "$label" ] && [ "$label" != "$title" ] && tail_seg="$label"

  ROWS+=("${id}${US}${row}${US}${tail_seg}")
done
[ "${#ROWS[@]}" -eq 0 ] && exit 0

# Measure, truncate and emit. Perl because width has to be counted in display
# columns, not codepoints: a CJK character occupies two. Counting codepoints
# made a 126-column budget render as 221 columns and wrap onto the next row.
printf '%s\n' "${ROWS[@]}" | perl -CSDA -e '
my $cols = shift @ARGV;
my $US   = "\x1f";

# East Asian Wide/Fullwidth ranges, plus the emoji planes. A char that renders
# two columns wide but is missing here is undercounted and the row overruns.
sub wide {
    my $o = shift;
    return 1 if ($o >= 0x1100 && $o <= 0x115F)
             || ($o >= 0x2E80 && $o <= 0x303E)
             || ($o >= 0x3041 && $o <= 0x33FF)
             || ($o >= 0x3400 && $o <= 0x4DBF)
             || ($o >= 0x4E00 && $o <= 0x9FFF)
             || ($o >= 0xA000 && $o <= 0xA4CF)
             || ($o >= 0xAC00 && $o <= 0xD7A3)
             || ($o >= 0xF900 && $o <= 0xFAFF)
             || ($o >= 0xFE30 && $o <= 0xFE6F)
             || ($o >= 0xFF00 && $o <= 0xFF60)
             || ($o >= 0xFFE0 && $o <= 0xFFE6)
             || ($o >= 0x1F000 && $o <= 0x1FAFF)
             || $o == 0x26A1;   # high voltage, used as the fast-mode flag
    return 0;
}

sub vislen {
    my $s = shift;
    $s =~ s/\e\[[0-9;]*m//g;
    my $n = 0;
    $n += wide(ord($_)) ? 2 : 1 for split //, $s;
    return $n;
}

# Truncate to a column budget, counting display columns and never splitting a
# character. Returns the kept prefix.
sub trunc {
    my ($s, $budget) = @_;
    my ($out, $w) = ("", 0);
    for my $c (split //, $s) {
        my $cw = wide(ord($c)) ? 2 : 1;
        last if $w + $cw > $budget;
        $out .= $c;
        $w   += $cw;
    }
    return $out;
}

sub jesc {
    my $s = shift;
    $s =~ s/([\\"])/\\$1/g;
    $s =~ s/([\x00-\x1f])/sprintf("\\u%04x", ord($1))/ge;
    return $s;
}

binmode(STDOUT, ":encoding(UTF-8)");
while (my $line = <STDIN>) {
    chomp $line;
    my ($id, $prefix, $desc) = split /$US/, $line, 3;
    next unless defined $id && length $id;
    $desc = "" unless defined $desc;

    my $used = vislen($prefix);

    # The prefix itself can exceed the budget on a very narrow panel; the old
    # version only ever truncated the description, so a long agent title blew
    # straight past `columns`.
    if ($used > $cols) {
        $prefix = trunc($prefix, $cols - 1) . "\x{2026}" . "\e[0m";
    } elsif (length $desc) {
        my $room = $cols - $used - 3;
        if ($room > 8) {
            if (vislen($desc) > $room) {
                $desc = trunc($desc, $room - 1) . "\x{2026}";
            }
            $prefix .= " \e[2m\x{b7}\e[0m \e[2m" . $desc . "\e[0m";
        }
    }
    printf "{\"id\":\"%s\",\"content\":\"%s\"}\n", jesc($id), jesc($prefix);
}
' "$COLS"
