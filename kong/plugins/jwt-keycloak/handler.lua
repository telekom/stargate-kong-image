local BasePlugin = require "kong.plugins.base_plugin"
local constants = require "kong.constants"
local jwt_decoder = require "kong.plugins.jwt.jwt_parser"
local socket = require "socket"
local keycloak_keys = require("kong.plugins.jwt-keycloak.keycloak_keys")

local validate_issuer = require("kong.plugins.jwt-keycloak.validators.issuers").validate_issuer
local validate_scope = require("kong.plugins.jwt-keycloak.validators.scope").validate_scope
local validate_roles = require("kong.plugins.jwt-keycloak.validators.roles").validate_roles
local validate_realm_roles = require("kong.plugins.jwt-keycloak.validators.roles").validate_realm_roles
local validate_client_roles = require("kong.plugins.jwt-keycloak.validators.roles").validate_client_roles

local re_gmatch = ngx.re.gmatch

local security_event = require("kong.plugins.jwt-keycloak.tardis.securitylog").security_event
local set_tardis_consumer = require("kong.plugins.jwt-keycloak.tardis.securitylog").collect_tardis_data

local JwtKeycloakHandler = BasePlugin:extend()

local priority_env_var = "JWT_KEYCLOAK_PRIORITY"
local priority
if os.getenv(priority_env_var) then
    priority = tonumber(os.getenv(priority_env_var))
else
    priority = 1005
end
kong.log.debug('JWT_KEYCLOAK_PRIORITY: ' .. priority)

JwtKeycloakHandler.PRIORITY = priority
JwtKeycloakHandler.VERSION = "1.1.0"

local function get_consumer_custom_id_cache_key(custom_id)
    return "custom_id_key_" .. custom_id
end

local function invalidate_customer(data)
    local customer = data.entity
    if data.operation == "update" then
        customer = data.old_entity
    end

    local key = get_consumer_custom_id_cache_key(customer.custom_id)
    kong.log.info("invalidating customer " .. key)
    kong.cache:invalidate(key)
end

function JwtKeycloakHandler:init_worker()
    JwtKeycloakHandler.super.init_worker(self)

    kong.worker_events.register(invalidate_customer, "crud", "consumers")
end

function table_to_string(tbl)
    local result = ""
    for k, v in pairs(tbl) do
        -- Check the key type (ignore any numerical keys - assume its an array)
        if type(k) == "string" then
            result = result.."[\""..k.."\"]".."="
        end

        -- Check the value type
        if type(v) == "table" then
            result = result..table_to_string(v)
        elseif type(v) == "boolean" then
            result = result..tostring(v)
        else
            result = result.."\""..v.."\""
        end
        result = result..","
    end
    -- Remove leading commas from the result
    if result ~= "" then
        result = result:sub(1, result:len()-1)
    end
    return result
end

--- Retrieve a JWT in a request.
-- Checks for the JWT in URI parameters, then in cookies, and finally
-- in the `Authorization` header.
-- @param request ngx request object
-- @param conf Plugin configuration
-- @return token JWT token contained in request (can be a table) or nil
-- @return err
local function retrieve_token(conf)
    local args = kong.request.get_query()
    for _, v in ipairs(conf.uri_param_names) do
        if args[v] then
            return args[v]
        end
    end

    local var = ngx.var
    for _, v in ipairs(conf.cookie_names) do
        local cookie = var["cookie_" .. v]
        if cookie and cookie ~= "" then
            return cookie
        end
    end

    local authorization_header = kong.request.get_header("authorization")
    if authorization_header then
        local iterator, iter_err = re_gmatch(authorization_header, "\\s*[Bb]earer\\s+(.+)")
        if not iterator then
            return nil, iter_err
        end

        local m, err = iterator()
        if err then
            return nil, err
        end

        if m and #m > 0 then
            return m[1]
        end
    end
end

function JwtKeycloakHandler:new()
    JwtKeycloakHandler.super.new(self, "jwt-keycloak")
end

local function load_consumer(consumer_id, anonymous)
    local result, err = kong.db.consumers:select { id = consumer_id }
    if not result then
        if anonymous and not err then
            err = 'anonymous consumer "' .. consumer_id .. '" not found'
        end
        return nil, err
    end
    return result
end

local function load_consumer_by_custom_id(custom_id)
    local result, err = kong.db.consumers:select_by_custom_id(custom_id)
    if not result then
        return nil, err
    end
    return result
end

local function set_consumer(consumer, credential, token)
    local set_header = kong.service.request.set_header
    local clear_header = kong.service.request.clear_header

    if consumer and consumer.id then
        set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
    else
        clear_header(constants.HEADERS.CONSUMER_ID)
    end

    if consumer and consumer.custom_id then
        kong.log.debug("found consumer " .. consumer.custom_id)
        set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
    else
        clear_header(constants.HEADERS.CONSUMER_CUSTOM_ID)
    end

    if consumer and consumer.username then
        set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
    else
        clear_header(constants.HEADERS.CONSUMER_USERNAME)
    end

    kong.client.authenticate(consumer, credential)

    if credential then
        kong.ctx.shared.authenticated_jwt_token = token -- TODO: wrap in a PDK function?
        ngx.ctx.authenticated_jwt_token = token  -- backward compatibilty only

        if credential.username then
            set_header(constants.HEADERS.CREDENTIAL_USERNAME, credential.username)
        else
            clear_header(constants.HEADERS.CREDENTIAL_USERNAME)
        end

        clear_header(constants.HEADERS.ANONYMOUS)

    else
        clear_header(constants.HEADERS.CREDENTIAL_USERNAME)
        set_header(constants.HEADERS.ANONYMOUS, true)
    end
end

local function get_keys(well_known_endpoint)
    kong.log.debug('Getting public keys from keycloak')
    local keys, err = keycloak_keys.get_issuer_keys(well_known_endpoint)
    if err then
        return nil, err
    end

    local decoded_keys = {}
    for i, key in ipairs(keys) do
        decoded_keys[i] = jwt_decoder:base64_decode(key)
    end

    kong.log.debug('Number of keys retrieved: ' .. table.getn(decoded_keys))
    return {
        keys = decoded_keys,
        updated_at = socket.gettime(),
    }
end

local function validate_signature(conf, jwt, second_call)
    local issuer_cache_key = 'issuer_keys_' .. jwt.claims.iss

    local well_known_endpoint = keycloak_keys.get_wellknown_endpoint(conf.well_known_template, jwt.claims.iss)
    -- Retrieve public keys
    local public_keys, err = kong.cache:get(issuer_cache_key, nil, get_keys, well_known_endpoint, true)

    if not public_keys then
        if err then
            kong.log.err(err)
        end
        security_event(221, 'public_key_not_available')
        return kong.response.exit(403, { message = "Unable to get public key for issuer" })
    end

    -- Verify signatures
    for _, k in ipairs(public_keys.keys) do
        if jwt:verify_signature(k) then
            kong.log.debug('JWT signature verified')
            return nil
        end
    end

    -- We could not validate signature, try to get a new keyset?
    since_last_update = socket.gettime() - public_keys.updated_at
    if not second_call and since_last_update > conf.iss_key_grace_period then
        kong.log.debug('Could not validate signature. Keys updated last ' .. since_last_update .. ' seconds ago')
        kong.cache:invalidate_local(issuer_cache_key)
        return validate_signature(conf, jwt, true)
    end

    security_event(222, 'invalid_token_signature')
    return kong.response.exit(401, { message = "Invalid token signature" })
end

local function match_consumer(conf, jwt)
    local consumer, err
    local consumer_id = jwt.claims[conf.consumer_match_claim]

    if conf.consumer_match_claim_custom_id then
        local consumer_cache_key = get_consumer_custom_id_cache_key(consumer_id)
        consumer, err = kong.cache:get(consumer_cache_key, nil, load_consumer_by_custom_id, consumer_id, true)
    else
        local consumer_cache_key = kong.db.consumers:cache_key(consumer_id)
        consumer, err = kong.cache:get(consumer_cache_key, nil, load_consumer, consumer_id, true)
    end

    if err then
        kong.log.err(err)
    end

    if not consumer and not conf.consumer_match_ignore_not_found then
        kong.log.warn("Unable to find consumer " .. consumer_id .." for token")
        return false, { status = 401, message = "Unable to find consumer " .. consumer_id .." for token" }
    end

    if consumer then
        set_consumer(consumer, nil, nil)
    end

    return true
end

local function do_authentication(conf)
    -- Retrieve token
    local token, err = retrieve_token(conf)
    if err then
        kong.log.err(err)
        return kong.response.exit(500, { message = "An unexpected error occurred" })
    end

    local token_type = type(token)
    if token_type ~= "string" then
        if token_type == "nil" then
            security_event(200, 'token_not_provided')
            return false, { status = 401, message = "Unauthorized" }
        elseif token_type == "table" then
            security_event(200, 'multiple_tokens_provided')
            return false, { status = 401, message = "Multiple tokens provided" }
        else
            security_event(200, 'unrecognizable_token')
            return false, { status = 401, message = "Unrecognizable token" }
        end
    end

    -- Decode token
    local jwt, err = jwt_decoder:new(token)
    if err then
        security_event(201, 'token_integrity_wrong')
        return false, { status = 401, message = "Bad token; " .. tostring(err) }
    end

    -- Verify algorithim
    if jwt.header.alg ~= (conf.algorithm or "HS256") then
        security_event(201, 'token_integrity_wrong')
        return false, {status = 403, message = "Invalid algorithm"}
    end

    set_tardis_consumer(jwt)
    -- Verify the JWT registered claims
    local ok_claims, errors = jwt:verify_registered_claims(conf.claims_to_verify)
    if not ok_claims then
        security_event(202, 'token_timed_out')
        return false, { status = 401, message = "Token claims invalid: " .. table_to_string(errors) }
    end

    -- Verify maximum expiration
    if conf.maximum_expiration ~= nil and conf.maximum_expiration > 0 then
        local ok, errors = jwt:check_maximum_expiration(conf.maximum_expiration)
        if not ok then
            security_event(202, 'token_timed_out')
            return false, { status = 403, message = "Token claims invalid: " .. table_to_string(errors) }
        end
    end

    -- Verify that the issuer is allowed
    if not validate_issuer(conf.allowed_iss, jwt.claims) then
        -- TODO: dedicated security coden will be defined
        security_event(222, 'incorrect_issuer')
        return false, { status = 401, message = "Token issuer not allowed" }
    end

    err = validate_signature(conf, jwt)
    if err ~= nil then
        -- TODO: dedicated security coden will be defined
        security_event(220, 'incorrect_token_signature')
        return false, err
    end

    -- Match consumer
    if conf.consumer_match then
        local ok, err = match_consumer(conf, jwt)
        if not ok then
            security_event(207, 'consumer_match_failed') -- this case practically does not occur in the current rover configuration (because consumer_match not useed))
            return ok, err
        end
    end

    -- Verify roles or scopes
    -- These cases currently don't occur, but may become important with the introduction of scopes
    local ok, err = validate_scope(conf.scope, jwt.claims)

    if ok then
        ok, err = validate_realm_roles(conf.realm_roles, jwt.claims)
    else
        security_event(222, 'validate_scope_failed')
    end

    if ok then
        ok, err = validate_roles(conf.roles, jwt.claims)
    else
        security_event(222, 'validate_realm_roles_failed')
    end

    if ok then
        ok, err = validate_client_roles(conf.client_roles, jwt.claims)
    else
        security_event(222, 'validate_roles_failed')
    end

    if ok then
        kong.ctx.shared.jwt_keycloak_token = jwt
        return true
    else
        security_event(222, 'validate_client_roles_failed')
    end

    return false, { status = 403, message = "Access token does not have the required scope/role: " .. err }
end


function JwtKeycloakHandler:access(conf)
    JwtKeycloakHandler.super.access(self)

    -- check if preflight request and whether it should be authenticated
    if not conf.run_on_preflight and kong.request.get_method() == "OPTIONS" then
        return
    end

    if conf.anonymous and kong.client.get_credential() then
        -- we're already authenticated, and we're configured for using anonymous,
        -- hence we're in a logical OR between auth methods and we're already done.
        return
    end

    local ok, err = do_authentication(conf)
    if not ok then
        if conf.anonymous then
            -- get anonymous user
            local consumer_cache_key = kong.db.consumers:cache_key(conf.anonymous)
            local consumer, err      = kong.cache:get(consumer_cache_key, nil,
                                                    load_consumer,
                                                    conf.anonymous, true)
            if err then
                kong.log.err(err)
                return kong.response.exit(500, { message = "An unexpected error occurred" })
            end

            set_consumer(consumer, nil, nil)
        else
            return kong.response.exit(err.status, err.errors or { message = err.message })
        end
    end
end

return JwtKeycloakHandler