#!/usr/bin/env julia
#
# Check the pinned stdlib snapshot against the Julia running this script.
#
#     julia --project=bin bin/check_stdlibs.jl
#
# `bin/` pins HistoricalStdlibVersions in its manifests, and that package is a
# snapshot: it records what each Julia release bundles. A pin left behind by new
# Julia releases does not fail loudly, it answers wrongly -- a release newer than
# the pin is not missing from the data, it is described by an older stanza. So
# the resolver reports confidently about a Julia that never existed, and the
# report looks exactly like a real conflict. That is issue #103: the pin sat at
# 2.0.2, which predates 1.12, so 1.12.x was credited with 1.11's OpenSSL_jll
# 3.0.15 rather than the 3.5.x it ships, and OpenSSL_CLI_jll would not resolve
# on it at all.
#
# The running Julia carries the answer in its own stdlib directory, so that is
# what the snapshot is checked against. That comparison is the whole of what
# decides pass or fail: the check cannot fail merely because time passed, only
# because the pin misdescribes a Julia that is present.
#
# The registries are read only once drift is found, and only to say whose job
# the fix is. A pin behind the newest release is one bin/update_manifests.jl
# fixes here. A pin already at the newest release is a hole in the upstream data,
# and refreshing here closes nothing -- somebody has to regenerate and release
# HistoricalStdlibVersions first. Julia 1.13.1 was the second kind while this
# script insisted on the first, which cost an afternoon of running a script that
# could not have helped.
#
# Coverage is one Julia per run, so .github/workflows/stdlibs.yml runs it across
# the range the bin/ manifests support. Prereleases are skipped: see below.
# Exits nonzero on drift.

push!(empty!(LOAD_PATH), @__DIR__)

include("Registries.jl")

import HistoricalStdlibVersions
import Pkg
import Base: UUID

function check_stdlibs(io::IO = stdout)
    # Only a released Julia has a settled answer to "what do you bundle". A
    # development build is a moving target -- `1.14.0-DEV.2617` is master at one
    # commit, while the snapshot's 1.14.0 stanza is master at another -- so the
    # two disagree for no reason anybody could fix, and on this machine's
    # nightly they disagree about eighteen stdlibs. Released versions are also
    # the only ones the bin/ manifests target, so skipping the rest costs the
    # check nothing it was meant to catch.
    if !isempty(VERSION.prerelease)
        println(io, "julia $VERSION is a prerelease: skipping the stdlib snapshot check")
        return true
    end
    bundled = host_stdlibs()
    snapshot = stdlib_snapshot(VERSION)
    names = Dict(uuid => info.name for (uuid, info) in snapshot)
    # The upgradable stdlibs are absent from the snapshot by design -- Julia
    # bundles them without pinning them, so registry versions compete with the
    # bundled one -- and their absence is not staleness.
    pinned = Dict(uuid => info.version
                  for (uuid, info) in snapshot
                  if info.version !== nothing &&
                     uuid ∉ UPGRADABLE_STDLIBS_UUIDS)
    absent = sort!([names[uuid] for uuid in setdiff(keys(pinned), keys(bundled))])
    drifted = sort!([(names[uuid], version, bundled[uuid])
                     for (uuid, version) in pinned
                     if haskey(bundled, uuid) && bundled[uuid] != version])
    println(io, "julia $VERSION: $(length(pinned)) stdlibs pinned by the snapshot, ",
                "$(length(bundled)) bundled")
    if isempty(absent) && isempty(drifted)
        println(io, "the pinned stdlib snapshot describes this Julia")
        return true
    end
    for name in absent
        println(io, "  missing: $name is pinned by the snapshot but not bundled here")
    end
    for (name, claimed, actual) in drifted
        println(io, "  drifted: $name -- snapshot says $claimed, this Julia ships $actual")
    end
    println(io)
    println(io, refresh_advice(VERSION, pinned_snapshot(), newest_snapshot()))
    return false
end

# The HistoricalStdlibVersions actually in force, which is what the manifest for
# this Julia pinned.
pinned_snapshot() = pkgversion(HistoricalStdlibVersions)

const SNAPSHOT_UUID = UUID("6df8b67a-e8a0-4029-b4b7-ac196fe72102")

# The newest HistoricalStdlibVersions the reachable registries offer, or
# `nothing` where they cannot be read -- offline, or a registry format this Pkg
# does not know. Not knowing is its own answer, and says so rather than guessing.
function newest_snapshot()
    best = nothing
    try
        for reg in Pkg.Registry.reachable_registries()
            haskey(reg.pkgs, SNAPSHOT_UUID) || continue
            info = Pkg.Registry.registry_info(reg, reg.pkgs[SNAPSHOT_UUID])
            for v in keys(info.version_info)
                if best === nothing || v > best
                    best = v
                end
            end
        end
    catch
        return nothing
    end
    return best
end

# What to do about drift, which depends entirely on whether the fix is available
# here. Pure in its arguments so every branch is reachable in a test; the
# headline is its own paragraph so an interpolated version cannot reflow it.
function refresh_advice(julia::VersionNumber,
                        pinned::VersionNumber,
                        newest::Union{Nothing,VersionNumber})
    head = "The stdlib snapshot does not describe julia $julia.\n"
    refresh = """
            julia --project=bin bin/update_manifests.jl

        and commit the bin/Manifest-*.toml changes."""
    newest === nothing && return """
        $head
        The registries could not be read, so whether a newer snapshot exists is
        unknown. If HistoricalStdlibVersions has a release newer than the pinned
        $pinned, this is the fix:

        $refresh

        If it does not, the gap is in the upstream data and refreshing here
        closes nothing."""
    newest > pinned && return """
        $head
        HistoricalStdlibVersions $newest is newer than the pinned $pinned, so
        refresh the pin:

        $refresh"""
    return """
        $head
        The pin is already at $pinned, the newest release there is, so
        bin/update_manifests.jl would change nothing. This is a hole in the
        upstream data rather than a stale pin: HistoricalStdlibVersions has no
        stanza for julia $julia.

        Closing it takes three steps across two repositories:

          1. regenerate the data -- dispatch the "Update Historical Stdlibs"
             workflow at JuliaPackaging/HistoricalStdlibVersions.jl, which opens
             a pull request with the new stanza;
          2. merge that, bump its Project.toml, and register the release;
          3. then refresh the pin here.

        Step 1 is the one to check first: that workflow runs only when somebody
        triggers it, so the data can be weeks behind a Julia release."""
end

# Guarded so the file can be included for its pieces -- bin/test/runtests.jl
# asserts the advice branches, which a bare call would `exit` out of.
if abspath(PROGRAM_FILE) == @__FILE__
    check_stdlibs() || exit(1)
end
