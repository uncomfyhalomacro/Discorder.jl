# Gateway tracker
@with_kw mutable struct GatewayTracker
    websocket::HTTP.WebSockets.WebSocket
    heartbeat_interval_ms::Int
    seq::Int = -1
    heartbeat_task::Optional{Task} = nothing
    processor_task::Optional{Task} = nothing
    master_task::Optional{Task} = nothing
    doctor_task::Optional{Task} = nothing
    terminate_flag::Bool = false
    ready::Bool = false
    events::Channel = Channel{Any}(100)
end

struct GatewayError <: Exception
    message::String
end

# ---------------------------------------------------------------------------
# Control plane
#
# The control plane consists of the following async processes:
# 1. Heartbeat: send heartbeat messages regularly to Discord gateway
# 2. Processor: receive and dispatch messages from Discord gateway
# 3. Doctor: monitor the health of the control plane and stop it when it's unhealthy
#
# The `run_control_plane` function starts a new control plane and wait for it to
# finish in a loop. Hence, if the doctor has diagnosed problems and stopped it,
# then a new control plane would come to live again.
# ---------------------------------------------------------------------------

function make_gateway_url(client::BotClient, version=API_VERSION)
    gateway = get_gateway(client)
    return "$(gateway.url)?v=$version&encoding=json"
end

"""
    start_control_plane(client::BotClient)

Start new control plane and return a `GatewayTracker` object.
"""
function start_control_plane(client::BotClient=BotClient())
    local tracker
    tracker_ready = Condition()
    task = @async try
        gateway_url = make_gateway_url(client)
        @info "Connecting to gateway" gateway_url

        HTTP.WebSockets.open(gateway_url) do websocket
            json = readavailable(websocket)
            @debug "Received" String(deepcopy(json))
            isempty(json) && throw(GatewayError("No data was received"))

            payload = JSON3.read(json, GatewayPayload)
            @debug "Parsed" payload.op payload.d
            payload.op == GatewayOpcode.Hello ||
                throw(GatewayError("Wrong opcode: $(payload.op)"))

            heartbeat_interval_ms = payload.d["heartbeat_interval"]
            tracker = GatewayTracker(; websocket, heartbeat_interval_ms)

            send_identify(tracker)

            @debug "Starting heartbeat and processor tasks"
            start_heartbeat(tracker)
            start_processor(tracker)
            notify(tracker_ready)

            @debug "Waiting for heartbeat and processor tasks"
            @debug "heartbeat_task = $(tracker.heartbeat_task)"
            @debug "processor_task = $(tracker.processor_task)"
            safe_wait(tracker.heartbeat_task)
            safe_wait(tracker.processor_task)

            @info "Finished control plane process"
        end
    catch ex
        @error "Unable to start control plane (phase 1): $ex"
        show_error(ex)
    end

    try
        @debug "Waiting for tracker to be ready"
        safe_wait(tracker_ready)

        tracker.master_task = task

        # make sure everything is up and running before starting doctor process
        @debug "Waiting for heartbeat task to get started"
        wait_for_task_to_get_scheduled(tracker.heartbeat_task, :heartbeat)

        @debug "Waiting for processor task to get started"
        wait_for_task_to_get_scheduled(tracker.processor_task, :processor)

        @debug "Starting doctor task"
        start_doctor(tracker)
        wait_for_task_to_get_scheduled(tracker.doctor_task, :doctor)

        @info "Control plane started successfully" tracker
    catch ex
        @error "Unable to start control plane (phase 2): $ex"
        show_error(ex)
    end
    return tracker
end

function safe_wait(task)
    try
        wait(task)
    catch ex
        if ex isa MethodError && length(ex.args) > 0 && isnothing(ex.args[1])
            @warn "Task already be set to nothing by control plane doctor?"
        else
            @warn "Unable to wait for task" ex
            show_error(ex)
        end
    end
end

function default_token()
    token = get(ENV, "DISCORD_BOT_TOKEN", "")
    isempty(token) && error("Please define DISCORD_BOT_TOKEN environemnt variable.")
    return token
end

# https://discord.com/developers/docs/topics/gateway#identifying
function send_identify(tracker::GatewayTracker)
    @info "Sending IDENTIFY payload"
    payload = GatewayPayload(;
        op=GatewayOpcode.Identify,
        d=Identify(;
            token=default_token(),
            intents=Int(0x01ffff),
            properties=IdentifyConnectionProperties(;
                os_="linux", browser_="Discorder", device_="Discorder"
            ),
        ),
    )
    return send_payload(tracker.websocket, payload)
end

# Run control plane in a loop so that we can actually auto-recover
function run_control_plane(;
    client::BotClient=BotClient(), tracker_ref=Ref{GatewayTracker}(), debug=false
)
    with_logger(get_logger(; debug)) do
        while true
            @info "Starting a new control plane"
            elapsed_seconds = @elapsed tracker_ref[] = start_control_plane(client)
            @info "Started control plane" elapsed_seconds
            safe_wait(tracker_ref[].master_task)
            tracker_ref[].terminate_flag && break
        end
        @info "Control plan has been fully shut down"
    end
end

# The doctor is responsible for ensuring the healthiness of the control plane.
function start_doctor(tracker::GatewayTracker)
    tracker.doctor_task = @async try
        while true
            if !is_operational(tracker)
                @info "Gateway is not healthy, stopping control plane" tracker
                sleep(5)
                stop_control_plane(tracker)
                break
            end
            sleep(1)
        end
    catch ex
        @error "Unexpected exception in doctor task: $ex"
        show_error(ex)
    end
    return tracker.doctor_task
end

function send_payload(ws::HTTP.WebSockets.WebSocket, payload::GatewayPayload)
    try
        str = json(payload)
        @debug "Sending payload" str
        write(ws, str)
        @debug "Finished sending payload"
    catch ex
        @error "Unable to send gateway payload: $ex"
        show_error(ex)
        rethrow(ex)
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Heartbeat
# ---------------------------------------------------------------------------

# See https://discord.com/developers/docs/topics/gateway#heartbeating
function start_heartbeat(tracker::GatewayTracker)
    tracker.heartbeat_task = @async try
        while true
            # Setting seq to `nothing` would force sending a `null`. See doc:
            # https://discord.com/developers/docs/topics/gateway#heartbeat
            seq = tracker.seq < 0 ? nothing : tracker.seq
            payload = GatewayPayload(; op=GatewayOpcode.Heartbeat, d=seq)
            send_payload(tracker.websocket, payload)
            jitter = rand()  # should be between 0 and 1 per API Reference
            nap = tracker.heartbeat_interval_ms / 1000 * jitter
            @info "Sent heartbeat, taking nap now." nap
            sleep(nap)
        end
        @debug "Finished heartbeat loop"
    catch ex
        if ex isa InterruptException
            @info "Heartbeat loop stopped by control plane"
        else
            @error "Heartbeat loop exited with error" ex
            show_error(ex)
        end
    end
    return tracker.heartbeat_task
end

stop_heartbeat(tracker::GatewayTracker) = stop_task(tracker, :heartbeat_task)

# ---------------------------------------------------------------------------
# Processor
# ---------------------------------------------------------------------------

function start_processor(tracker::GatewayTracker)
    tracker.processor_task = @async try
        while true
            if isopen(tracker.websocket)
                json = readavailable(tracker.websocket)
                @debug "Received" String(deepcopy(json))
                if !isempty(json)
                    payload = JSON3.read(json, GatewayPayload)
                    @debug "Parsed" payload.op payload.t payload.d payload.s
                    if payload.s isa Integer
                        tracker.seq = payload.s  # sync sequence number
                    end
                    if payload.op === GatewayOpcode.Resume
                        # https://discord.com/developers/docs/topics/gateway#resumed
                        object = (; event_type="RESUME")
                        put!(tracker.events, object)
                    elseif payload.op === GatewayOpcode.Reconnect
                        # https://discord.com/developers/docs/topics/gateway#reconnect
                        object = (; event_type="RECONNECT")
                        put!(tracker.events, object)
                    elseif payload.op === GatewayOpcode.InvalidSession
                        # https://discord.com/developers/docs/topics/gateway#invalid-session
                        object = make_object("INVALID_SESSION", JSON3.write(payload.d))
                        put!(tracker.events, object)
                    elseif !isnothing(payload.t) && !isnothing(payload.d)
                        # TODO: this is hacky... converting it back to json string and re-parse as object
                        object = make_object(payload.t, JSON3.write(payload.d))
                        put!(tracker.events, object)
                    end
                else
                    @error "Received empty array"
                    break
                end
            else
                @error "oops, websocket is no longer open" tracker.websocket
                break
            end
        end
    catch ex
        if ex isa InterruptException
            @info "Processor loop stopped by control plane"
        else
            @error "Processor loop error" ex
            show_error(ex)
        end
    end
    return tracker.processor_task
end

stop_processor(tracker::GatewayTracker) = stop_task(tracker, :processor_task)

# ---------------------------------------------------------------------------
# Control plane utils
# ---------------------------------------------------------------------------

# General function that can be used to stop any tasks in the GatewayTracker
# Return `true` if the task has been stopped successfully.
function stop_task(tracker::GatewayTracker, task_field::Symbol)
    task = getproperty(tracker, task_field)
    if isnothing(task)
        @info "Task does not exist anymore" task_field
        return true
    end
    @info "Stopping task" task_field task
    wait_seconds = 5
    sleep_time = 0.1
    max_iterations = wait_seconds / sleep_time
    cnt = 1
    try
        while cnt <= max_iterations
            @async Base.throwto(task, InterruptException())
            if istaskdone(task)
                setproperty!(tracker, task_field, nothing)
                @info "Stopped task successfully" task_field task
                return true
            end
            sleep(sleep_time)
            cnt += 1
            @debug "Ensuring task is stopped" task_field task
        end
        @error "Unable to stop task" task_field task
        return false
    catch ex
        @error "Unexpected exception while stopping task" ex task_field task
        show_error(ex)
        return false
    end
end

function stop_control_plane(tracker::GatewayTracker)
    stop_processor(tracker)
    return stop_heartbeat(tracker)
end

is_connected(tracker::GatewayTracker) = isopen(tracker.websocket)

is_task_runnable(t::Task) = istaskstarted(t) && !istaskdone(t)
is_task_runnable(::Nothing) = false   # stopped tasks has `nothing` value

function shutdown(tracker::GatewayTracker)
    tracker.terminate_flag = true
    return stop_control_plane(tracker)
end

function is_operational(tracker::GatewayTracker)
    if !is_connected(tracker)
        @error "Websocket already closed"
        return false
    end
    if !is_task_runnable(tracker.heartbeat_task)
        @error "Heartbeat task not running anymore"
        return false
    end
    if !is_task_runnable(tracker.processor_task)
        @error "Processor task not running anymore"
        return false
    end
    return true
end

doctor_around(tracker::GatewayTracker) = is_task_runnable(tracker.doctor_task)

# In general, tasks started with @async should be schedulded immediately.
# But if it doesn't, then we can wait a little bit before giving up.
function wait_for_task_to_get_scheduled(task::Task, label::Symbol)
    max_wait_time = Second(30)
    start_ts = now()
    while true
        elapsed = now() - start_ts
        elapsed > max_wait_time && break
        if istaskstarted(task)
            @info "Task scheduled!" task label elapsed
            return nothing
        end
        sleep(0.1)
    end
    @warn "waiting for task to be scheduled but it never got started" task
    return nothing
end

function event_object_mappings()
    return Dict(
        # https://discord.com/developers/docs/topics/gateway#ready
        "READY" => ReadyEvent,

        # https://discord.com/developers/docs/topics/gateway#guilds
        "GUILD_CREATE" => Guild,
        "GUILD_UPDATE" => Guild,
        "GUILD_DELETE" => UnavailableGuild,
        "GUILD_ROLE_CREATE" => GuildRoleCreateEvent,
        "GUILD_ROLE_UPDATE" => GuildRoleUpdateEvent,
        "GUILD_ROLE_DELETE" => GuildRoleDeleteEvent,

        # https://discord.com/developers/docs/topics/gateway#channels
        "CHANNEL_CREATE" => Channel,
        "CHANNEL_UPDATE" => Channel,
        "CHANNEL_DELETE" => Channel,
        "CHANNEL_PINS_UPDATE" => ChannelPinsUpdateEvent,
        "THREAD_CREATE" => Channel,
        "THREAD_UPDATE" => Channel,
        "THREAD_DELETE" => Channel,
        "THREAD_LIST_SYNC" => ThreadListSyncEvent,
        "THREAD_MEMBER_UPDATE" => ThreadMember,
        "THREAD_MEMBERS_UPDATE" => ThreadMembersUpdateEvent,

        # https://discord.com/developers/docs/topics/gateway#stage-instances
        "STAGE_INSTANCE_CREATE" => StageInstance,
        "STAGE_INSTANCE_UPDATE" => StageInstance,
        "STAGE_INSTANCE_DELETE" => StageInstance,

        # https://discord.com/developers/docs/topics/gateway#guild-member-add
        "GUILD_MEMBER_ADD" => GuildMember,
        "GUILD_MEMBER_UPDATE" => GuildMemberUpdateEvent,
        "GUILD_MEMBER_REMOVE" => GuildMemberRemoveEvent,

        # https://discord.com/developers/docs/topics/gateway#guild-ban-add
        "GUILD_BAN_ADD" => GuildBanAddEvent,
        "GUILD_BAN_REMOVE" => GuildBanRemoveEvent,
        "GUILD_EMOJIS_UPDATE" => GuildEmojisUpdateEvent,
        "GUILD_STICKERS_UPDATE" => GuildStickersUpdateEvent,

        # https://discord.com/developers/docs/topics/gateway#guild-integrations-update
        "GUILD_INTEGRATIONS_UPDATE" => GuildIntegrationsUpdateEvent,
        "INTEGRATION_CREATE" => Integration,
        "INTEGRATION_UPDATE" => Integration,
        "INTEGRATION_DELETE" => IntegrationDeleteEvent,

        # https://discord.com/developers/docs/topics/gateway#invites
        "INVITE_CREATE" => InviteCreateEvent,
        "INVITE_DELETE" => InviteDeleteEvent,

        # https://discord.com/developers/docs/topics/gateway#presence
        "PRESENCE_UPDATE" => PresenceUpdateEvent,

        # https://discord.com/developers/docs/topics/gateway#messages
        "MESSAGE_CREATE" => Message,
        "MESSAGE_UPDATE" => Message,
        "MESSAGE_DELETE" => MessageDeleteEvent,
        "MESSAGE_DELETE_BULK" => MessageDeleteBulkEvent,

        # https://discord.com/developers/docs/topics/gateway#message-reaction-add
        "MESSAGE_REACTION_ADD" => MessageReactionAddEvent,
        "MESSAGE_REACTION_REMOVE" => MessageReactionRemoveEvent,
        "MESSAGE_REACTION_REMOVE_ALL" => MessageReactionRemoveAllEvent,
        "MESSAGE_REACTION_REMOVE_EMOJI" => MessageReactionRemoveEmojiEvent,

        # https://discord.com/developers/docs/topics/gateway#typing-start
        "TYPING_START" => TypingStartEvent,

        # https://discord.com/developers/docs/topics/gateway#guild-scheduled-event-create
        "GUILD_SCHEDULED_EVENT_CREATE" => GuildScheduledEvent,
        "GUILD_SCHEDULED_EVENT_UPDATE" => GuildScheduledEvent,
        "GUILD_SCHEDULED_EVENT_DELETE" => GuildScheduledEvent,
        "GUILD_SCHEDULED_EVENT_USER_ADD" => GuildScheduledEventUserAddEvent,
        "GUILD_SCHEDULED_EVENT_USER_REMOVE" => GuildScheduledEventUserRemoveEvent,
    )
end

function make_object(event_type::AbstractString, json::Optional{AbstractString})
    mappings = event_object_mappings()
    T = haskey(mappings, event_type) ? mappings[event_type] : Any
    try
        object = JSON3.read(json, T)
        return (; event_type, object)
    catch ex
        @error "Unable to parse JSON string" json T event_type ex
    end
end
