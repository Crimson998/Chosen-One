--!strict
-- Declarative Instance construction for UI code:
--   Create("TextLabel", { Text = "Hi", Parent = frame }, { Create("UICorner", {}) })
-- Parent is applied last so the instance is fully configured before it
-- enters the DataModel.

local function Create(className: string, props: { [string]: any }, children: { any }?): any
	local instance = Instance.new(className)
	local parent: Instance? = nil
	for key, value in props do
		if key == "Parent" then
			parent = value
		else
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child: Instance in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

return Create
