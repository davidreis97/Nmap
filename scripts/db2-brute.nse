description = [[
Performs password guessing against IBM DB2
]]

---
-- @usage
-- nmap -p 50000 --script db2-brute <host>
--
-- @output
-- 50000/tcp open  ibm-db2
-- | db2-brute:  
-- |_  db2admin:db2admin => Login Correct
--
--
-- @args db2-brute.threads the amount of accounts to attempt to brute force in parallell (default 10)
-- @args db2-brute.dbname the database name against which to guess passwords (default SAMPLE)
--

author = "Patrik Karlsson"
license = "Same as Nmap--See http://nmap.org/book/man-legal.html"
categories={"intrusive", "auth"}

require "stdnse"
require "shortport"
require "db2"
require "unpwdb"

-- Version 0.3
-- Created 05/08/2010 - v0.1 - created by Patrik Karlsson <patrik@cqure.net>
-- Revised 05/09/2010 - v0.2 - re-wrote as multi-threaded <patrik@cqure.net>
-- Revised 05/10/2010 - v0.3 - revised parallellised design <patrik@cqure.net>

portrule = shortport.port_or_service({50000,60000},"ibm-db2", "tcp", {"open", "open|filtered"})

--- Credential iterator
--
-- @param usernames iterator from unpwdb
-- @param passwords iterator from unpwdb
-- @return username string
-- @return password string
local function new_usrpwd_iterator (usernames, passwords)
	local function next_username_password ()
		for username in usernames do
			for password in passwords do
				coroutine.yield(username, password)
			end
			passwords("reset")
		end
		while true do coroutine.yield(nil, nil) end
	end
	return coroutine.wrap(next_username_password)
end

--- Iterates over the password list and guesses passwords
--
-- @param host table with information as recieved by <code>action</code>
-- @param port table with information as recieved by <code>action</code>
-- @param database string containing the database name
-- @param username string containing the username against which to guess
-- @param valid_accounts table in which to store found accounts
doLogin = function( host, port, database, creds, valid_accounts )
	local helper, status, response, passwords
	local condvar = nmap.condvar( valid_accounts )

	for username, password in creds do
		-- Checks if a password was already discovered for this account
		if ( nmap.registry.db2users == nil or nmap.registry.db2users[username] == nil ) then
			helper = db2.Helper:new()
			helper:connect( host, port )		
			stdnse.print_debug( "Trying %s/%s against %s...", username, password, host.ip )
			status, response = helper:login( database, username, password )
			helper:close()
	
			if ( status ) then
				-- Add credentials for future db2 scripts to use
				if nmap.registry.db2users == nil then
					nmap.registry.db2users = {}
				end	
				nmap.registry.db2users[username]=password
				table.insert( valid_accounts, string.format("%s:%s => Login Correct", username, password:len()>0 and password or "<empty>" ) )
			end
		end
	end	
	condvar("broadcast")
end

--- Checks if the supplied database exists
--
-- @param host table with information as recieved by <code>action</code>
-- @param port table with information as recieved by <code>action</code>
-- @param database string containing the database name
-- @return status true on success, false on failure
isValidDb = function( host, port, database )
	local status, response
	local helper = db2.Helper:new()
	
	helper:connect( host, port )
	-- Authenticate with a static probe account to see if the db is valid		
	status, response = helper:login( database, "dbnameprobe1234", "dbnameprobe1234" )
	helper:close()

	if ( not(status) and response:match("Database not found") ) then
		return false
	end
	return true
end

--- Returns the amount of currenlty active threads
--
-- @param threads table containing the list of threads
-- @return count number containing the number of non-dead threads
threadCount = function( threads )
	local count = 0
	
	for thread in pairs(threads) do
		if ( coroutine.status(thread) == "dead" ) then
			threads[thread] = nil
		else
			count = count + 1
		end
	end
	return count
end

action = function( host, port )

	local result, response, status = {}, nil, nil
	local valid_accounts, threads = {}, {}	
	local usernames, passwords, creds
	local database = nmap.registry.args['db2-brute.dbname'] or "SAMPLE"
	local condvar = nmap.condvar( valid_accounts )
	local max_threads = nmap.registry.args['db2-brute.threads'] and tonumber( nmap.registry.args['db2-brute.threads'] ) or 10

	-- Check if the DB specified is valid
	if( not(isValidDb(host, port, database)) ) then
		return ("The databases %s was not found. (Use --script-args db2-brute.dbname=<dbname> to specify database)"):format(database)
	end

 	status, usernames = unpwdb.usernames()
	if ( not(status) ) then
		return "Failed to load usernames"
	end
	
	-- make sure we have a valid pw file
	status, passwords = unpwdb.passwords()
	if ( not(status) ) then
		return "Failed to load passwords"
	end
	
	creds = new_usrpwd_iterator( usernames, passwords )
	
	stdnse.print_debug("Starting brute force with %d threads", max_threads )
	
	for i=1,max_threads do	
		local co = stdnse.new_thread( doLogin, host, port, database, creds, valid_accounts )
		threads[co] = true
	end

	-- wait for all threads to finnish running
	while threadCount(threads)>0 do
   		condvar("wait")
 	end

	return stdnse.format_output(true, valid_accounts)	

end