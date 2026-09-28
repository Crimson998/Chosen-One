--!strict
-- Minimal pure-Luau signal used for in-process events between services.

type Handler = (...any) -> ()

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type ConnectionRecord = {
	Connected: boolean,
	Handler: Handler,
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, handler: Handler) -> Connection,
	Once: (self: Signal, handler: Handler) -> Connection,
	Fire: (self: Signal, ...any) -> (),
	Wait: (self: Signal) -> ...any,
	DisconnectAll: (self: Signal) -> (),
}

local Signal = {}

function Signal.new(): Signal
	local records: { ConnectionRecord } = {}
	local self = {} :: Signal

	local function disconnect(record: ConnectionRecord)
		if not record.Connected then
			return
		end
		record.Connected = false
		local index = table.find(records, record)
		if index then
			table.remove(records, index)
		end
	end

	function self.Connect(_: Signal, handler: Handler): Connection
		local record: ConnectionRecord
		record = {
			Connected = true,
			Handler = handler,
			Disconnect = function()
				disconnect(record)
			end,
		}
		table.insert(records, record)
		return record :: any
	end

	function self.Once(signal: Signal, handler: Handler): Connection
		local connection: Connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			handler(...)
		end)
		return connection
	end

	function self.Fire(_: Signal, ...: any)
		-- Snapshot so handlers may connect/disconnect while we iterate.
		for _, record in table.clone(records) do
			if record.Connected then
				task.spawn(record.Handler, ...)
			end
		end
	end

	function self.Wait(signal: Signal): ...any
		local thread = coroutine.running()
		signal:Once(function(...)
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end

	function self.DisconnectAll(_: Signal)
		for _, record in table.clone(records) do
			disconnect(record)
		end
	end

	return self
end

return Signal
