-- tenx-adminjail/server/permissions.lua
-- SERVER-ONLY. This file is never sent to clients, so admin licenses stay private.
--
-- HOW TO ADD A STAFF MEMBER:
--   Add a new line:  ['license:THEIR_LICENSE_HERE'] = 'Their Name',
--   then restart the resource (or /refresh + /ensure tenx-adminjail).
--
-- HOW TO REMOVE ONE:  delete their line and restart.
--
-- Only identifiers of type "license:" are used (matches the ones you provided).

Config = Config or {}

Config.Admins = {
    ['license:PUT_YOUR_LICENSE_IDENTIFIER_HERE'] = 'Staff 1', -- rename anytime
    ['license:PUT_A_SECOND_ADMIN_LICENSE_HERE'] = 'Staff 2', -- rename anytime
}