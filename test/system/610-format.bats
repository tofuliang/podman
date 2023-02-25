#!/usr/bin/env bats   -*- bats -*-
#
# PR #15673: For all commands that accept --format '{{.GoTemplate}}',
# invoke with --format '{{"\n"}}' and make sure they don't choke.
#

load helpers

function teardown() {
    # In case test fails: standard teardown does not wipe machines or secrets
    run_podman '?' machine rm -f mymachine
    run_podman '?' secret rm mysecret

    basic_teardown
}

# Most commands can't just be run with --format; they need an argument or
# option. This table defines what those are.
#
# FIXME: once you've finished fixing them all, remove the SKIPs (just
# remove the entire lines, except for pod-inspect, just remove the SKIP
# but leave "mypod")
extra_args_table="
history           | $IMAGE
image history     | $IMAGE
image inspect     | $IMAGE
container inspect | mycontainer

volume inspect    | -a
secret inspect    | mysecret
network inspect   | podman
ps                | -a

image search      | $IMAGE
search            | $IMAGE

pod inspect       | mypod

events            | --stream=false --events-backend=file
system events     | --stream=false --events-backend=file
"

# podman machine is finicky. Assume we can't run it, but see below for more.
can_run_podman_machine=

# podman stats, too
can_run_stats=

# Main test loop. Recursively runs 'podman [subcommand] help', looks for:
#    > '[command]', which indicates, recurse; or
#    > '--format', in which case we
#      > check autocompletion, look for Go templates, in which case we
#        > run the command with --format '{{"\n"}}' and make sure it passes
function check_subcommand() {
    for cmd in $(_podman_commands "$@"); do
        # Special case: 'podman machine' can only be run under ideal conditions
        if [[ "$cmd" = "machine" ]] && [[ -z "$can_run_podman_machine" ]]; then
            continue
        fi
        if [[ "$cmd" = "stats" ]] && [[ -z "$can_run_stats" ]]; then
            continue
        fi

        # Human-readable podman command string, with multiple spaces collapsed
        command_string="podman $* $cmd"
        command_string=${command_string//  / }  # 'podman  x' -> 'podman x'

        # Run --help, decide if this is a subcommand with subcommands
        run_podman "$@" $cmd --help
        local full_help="$output"

        # The line immediately after 'Usage:' gives us a 1-line synopsis
        usage=$(echo "$full_help" | grep -A1 '^Usage:' | tail -1)
        assert "$usage" != "" "podman $cmd: no Usage message found"

        # Strip off the leading command string; we no longer need it
        usage=$(sed -e "s/^  $command_string \?//" <<<"$usage")

        # If usage ends in '[command]', recurse into subcommands
        if expr "$usage" : '\[command\]' >/dev/null; then
            # (except for 'podman help', which is a special case)
            if [[ $cmd != "help" ]]; then
                check_subcommand "$@" $cmd
            fi
            continue
        fi

        # Not a subcommand-subcommand. Look for --format option
        if [[ ! "$output" =~ "--format" ]]; then
            continue
        fi

        # Have --format. Make sure it's a Go-template option, not like --push
        run_podman __completeNoDesc "$@" "$cmd" --format '{{.'
        if [[ ! "$output" =~ \{\{\.[A-Z] ]]; then
            continue
        fi

        # Got one.
        dprint "$command_string has --format"

        # Whatever is needed to make a runnable command
        local extra=${extra_args[$command_string]}
        if [[ -n "$extra" ]]; then
            # Cross off our list
            unset extra_args["$command_string"]
        fi

        # This is what does the work. We run with '?' so we can offer
        # better error messages than just "exited with error status".
        run_podman '?' "$@" "$cmd" $extra --format '{{"\n"}}'

        # Output must always be empty.
        #
        #  - If you see "unterminated quoted string" here, there's a
        #    regression, and you need to fix --format (see PR #15673)
        #
        #  - If you see any other error, it probably means that someone
        #    added a new podman subcommand that supports --format but
        #    needs some sort of option or argument to actually run.
        #    See 'extra_args_table' at the top of this script.
        #
        assert "$output" = "" "$command_string --format '{{\"\n\"}}'"

        # *Now* check exit status. This should never, ever, ever trigger!
        # If it does, it means the podman command failed without an err msg!
        assert "$status" = "0" \
               "$command_string --format '{{\"\n\"}}' failed with no output!"
    done
}

# Test entry point
@test "check Go template formatting" {
    skip_if_remote

    # Setup: some commands need a container, pod, secret, ...
    run_podman run -d --name mycontainer $IMAGE top
    run_podman pod create mypod
    run_podman secret create mysecret /etc/hosts

    # ...or machine. But podman machine is ultra-finicky, it fails as root
    # or if qemu is missing. Instead of checking for all the possible ways
    # to skip it, just try running init. If it works, we can test it.
    run_podman '?' machine init --image-path=/dev/null mymachine
    if [[ $status -eq 0 ]]; then
        can_run_podman_machine=true
        extra_args_table+="
machine inspect   | mymachine
"
    fi

    # Similarly, 'stats' cannot run rootless under cgroups v1
    if ! is_rootless || is_cgroupsv2; then
        can_run_stats=true
        extra_args_table+="
container stats   | --no-stream
pod stats         | --no-stream
stats             | --no-stream
"
    fi

    # Convert the table at top to an associative array, keyed on subcommand
    declare -A extra_args
    while read subcommand extra; do
        extra_args["podman $subcommand"]=$extra
    done < <(parse_table "$extra_args_table")

    # Run the test
    check_subcommand

    # Clean up
    run_podman pod rm mypod
    run_podman rmi $(pause_image)
    run_podman rm -f -t0 mycontainer
    run_podman secret rm mysecret
    run_podman '?' machine rm -f mymachine

    # Make sure there are no leftover commands in our table - this would
    # indicate a typo in the table, or a flaw in our logic such that
    # we're not actually recursing.
    local leftovers="${!extra_args[@]}"
    assert "$leftovers" = "" "Did not find (or test) subcommands:"
}

# vim: filetype=sh
