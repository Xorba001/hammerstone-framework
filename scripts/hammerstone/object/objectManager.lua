--- Hammerstone: objectManager.lua
-- This module controlls the registration of all Data Driven API objects. 
-- It will search the filesystem for mod files which should be loaded, and then
-- interact with Sapiens to create the objects.
-- @author SirLich, earmuffs

local objectManager = {
	inspectCraftPanelData = {},

	-- Map between storage identifiers and object IDENTIFIERS that should use this storage.
	-- Collected when generating objects, and inserted when generating storages (after converting to index)
	-- @format map<string, array<string>>.
	objectsForStorage = {},
}

-- Sapiens
local rng = mjrequire "common/randomNumberGenerator"

-- Math
local mjm = mjrequire "common/mjm"
local vec2 = mjm.vec2
local vec3 = mjm.vec3
local mat3Identity = mjm.mat3Identity
local mat3Rotate = mjm.mat3Rotate

-- Hammerstone
local log = mjrequire "hammerstone/logging"
local utils = mjrequire "hammerstone/object/objectUtils" -- TOOD: Are we happy name-bungling imports?
local moduleManager = mjrequire "hammerstone/state/moduleManager"
local configLoader = mjrequire "hammerstone/object/configLoader"
local objectDB = configLoader.configs


---------------------------------------------------------------------------------
-- Configuation and Loading
---------------------------------------------------------------------------------

-- Guards against the same code being run multiple times.
-- Takes in a unique ID to identify this code
local runOnceGuards = {}
local function runOnceGuard(guard)
	if runOnceGuards[guard] == nil then
		runOnceGuards[guard] = true
		return false
	end
	return true
end

--- Data structure which defines how a config is loaded, and in which order. 
-- @field moduleDependencies - Table list of modules which need to be loaded before this type of config is loaded
-- @field loaded - Whether the route has already been loaded
-- @field loadFunction - Function which is called when the config type will be loaded. Must take in a single param: the config to load!
-- @field waitingForStart - Whether this config is waiting for a custom trigger or not.
local objectLoader = {
	storage = {
		configSource = objectDB.storageConfigs,
		loaded = false,
		waitingForStart = false,
		moduleDependencies = {
			"storage"
		},
		loadFunction = "generateStorageObject" -- TODO: Find out how to run a function without accessing it via string
	},
	evolvingObject = {
		configSource = objectDB.objectConfigs,
		loaded = false,
		waitingForStart = false,
		moduleDependencies = {
			"evolvingObject",
			"gameObject"
		},
		loadFunction = "generateEvolvingObject"
	}
}

local function newModuleAdded(modules)
	objectManager:tryLoadObjectDefinitions()
end

moduleManager:bind(newModuleAdded)

-- Initialize the full Data Driven API (DDAPI).
function objectManager:init()
	if runOnceGuard("ddapi") then return end

	log:schema("ddapi", os.date())
	log:schema("ddapi", "\nInitializing DDAPI...")

	-- Load configs from FS
	configLoader:loadConfigs()
end


local function canLoadObjectType(objectName, objectData)
	-- Wait for configs to be loaded from the FS
	if configLoader.isInitialized == false then
		return false
	end

	-- Some routes wait for custom start logic. Don't start these until triggered!
	if objectData.waitingForStart == true then
		return false
	end

	-- Don't double-load objects
	if objectData.loaded == true then
		return false
	end

	-- Don't load until all dependencies are satisfied.
	for i, moduleDependency in pairs(objectData.moduleDependencies) do
		if moduleManager.modules[moduleDependency] == nil then
			return false
		end
	end

	-- If checks pass, then we can load the object
	objectData.loaded = true
	return true
end

--- Marks an object type as ready to load. 
-- @param configName the name of the config which is being marked as ready to load
function objectManager:markObjectAsReadyToLoad(configName)
	log:schema("ddapi", "Object is now ready to start loading: " .. configName)
	objectLoader[configName].waitingForStart = false
	objectManager:tryLoadObjectDefinitions() -- Re-trigger start logic, in case no more modules will be loaded.
end

--- Attempts to load object definitions from the objectLoader
function objectManager:tryLoadObjectDefinitions()
	mj:log("Attempting to load new object definitions:")
	for key, value in pairs(objectLoader) do
		if canLoadObjectType(key, value) then
			objectManager:loadObjectDefinition(key, value)
		end
	end
end

-- Loads a single object
function objectManager:loadObjectDefinition(objectName, objectData)
	log:schema("ddapi", "\nGenerating " .. objectName .. " definitions:")

	local configs = objectData.configSource
	if configs ~= nil and #configs ~= 0 then
		for i, config in ipairs(configs) do
			if config then
				objectManager[objectData.loadFunction](self, config) --Wtf oh my god
			else
				log:schema("ddapi", "WARNING: Attempting to generate nil " .. objectName)
			end
		end
	else
		log:schema("ddapi", "  (none)")
	end
end

---------------------------------------------------------------------------------
-- Resource
---------------------------------------------------------------------------------

--- Generates resource definitions based on the loaded config, and registers them.
-- @param resource - Module definition of resource.lua
function objectManager:generateResourceDefinitions()
	if runOnceGuard("resource") then return end
	log:schema("ddapi", "\nGenerating Resource definitions:")

	if objectDB.objectConfigs ~= nil and #objectDB.objectConfigs ~= 0 then
		for i, config in ipairs(objectDB.objectConfigs) do
			objectManager:generateResourceDefinition(config)
		end
	else
		log:schema("ddapi", "  (none)")
	end
end

function objectManager:generateResourceDefinition(config)
	-- TODO: Does this work?
	-- Modules
	local typeMapsModule = moduleManager:get("typeMaps")

	local objectDefinition = config["hammerstone:object_definition"]
	local description = objectDefinition["description"]
	local components = objectDefinition["components"]
	local identifier = description["identifier"]

	-- Resource links prevent a *new* resource from being generated.
	local resourceLinkComponent = components["hammerstone:resource_link"]
	if resourceLinkComponent ~= nil then
		log:schema("ddapi", "GameObject " .. identifier .. " linked to resource " .. resourceLinkComponent.identifier .. ". No unique resource created.")
		return
	end

	log:schema("ddapi", "  " .. identifier)

	local objectComponent = components["hammerstone:object"]
	local name = description["name"]
	local plural = description["plural"]

	local newResource = {
		key = identifier,
		name = name,
		plural = plural,
		displayGameObjectTypeIndex = typeMapsModule.types.gameObject[identifier],
	}

	-- Handle Food
	local foodComponent = components["hammerstone:food"]
	if foodComponent ~= nil then
		--if type() -- TODO
		newResource.foodValue = foodComponent.value
		newResource.foodPortionCount = foodComponent.portions

		-- TODO These should be implemented with a smarter default value check
		if foodComponent.food_poison_chance ~= nil then
			newResource.foodPoisoningChance = foodComponent.food_poison_chance
		end
		
		if foodComponent.default_disabled ~= nil then
			newResource.defaultToEatingDisabled = foodComponent.default_disabled
		end
	end

	-- TODO: Consider handling `isRawMeat` and `isCookedMeat` for purpose of tutorial integration.

	-- Handle Decorations
	local decorationComponent = components["hammerstone:decoration"]
	if decorationComponent ~= nil then
		newResource.disallowsDecorationPlacing = not decorationComponent["enabled"]
	end

	objectManager:registerObjectForStorage(identifier, components["hammerstone:storage_link"])
	moduleManager:get("resource"):addResource(identifier, newResource)
end

---------------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------------

--- Special helper function to generate the resource IDs that a storage should use, once they are available.
function objectManager:generateResourceForStorage(storageIdentifier)

	local newResource = {}

	local objectIdentifiers = objectManager.objectsForStorage[storageIdentifier]
	if objectIdentifiers ~= nil then
		for i, identifier in ipairs(objectIdentifiers) do
			table.insert(newResource, moduleManager:get("resource").types[identifier].index)
		end
	else
		log:schema("ddapi", "WARNING: Storage " .. storageIdentifier .. " is being generated with zero items. This is most likely a mistake.")
	end

	return newResource
end

function objectManager:generateStorageObject(config)
	-- Modules
	local storageModule = moduleManager:get("storage")
	local typeMapsModule = moduleManager:get("typeMaps")

	-- Load structured information
	local storageDefinition = config["hammerstone:storage_definition"]
	local description = storageDefinition["description"]
	local storageComponent = storageDefinition.components["hammerstone:storage"]
	local carryComponent = storageDefinition.components["hammerstone:carry"]

	local gameObjectTypeIndexMap = typeMapsModule.types.gameObject

	local identifier = utils:getField(description, "identifier")

	log:schema("ddapi", "  " .. identifier)

	-- Prep
	local random_rotation = utils:getField(storageComponent, "random_rotation_weight", {
		default = 2.0
	})
	local rotation = utils:getVec3(storageComponent, "rotation", {
		default = vec3(0.0, 0.0, 0.0)
	})

	local carryCounts = utils:getTable(carryComponent, "carry_count", {
		default = {} -- Allow this field to be undefined, but don't use nil
	})
	
	local newStorage = {
		key = identifier,
		name = utils:getField(description, "name"),

		displayGameObjectTypeIndex = gameObjectTypeIndexMap[utils:getField(storageComponent, "preview_object")],
		
		-- TODO: This needs to be reworked to make sure that it's possible to reference vanilla resources here (?)
		resources = objectManager:generateResourceForStorage(identifier),

		storageBox = {
			size =  utils:getVec3(storageComponent, "size", {
				default = vec3(0.5, 0.5, 0.5)
			}),
			
			-- TODO consider giving more control here
			rotationFunction = function(uniqueID, seed)
				local randomValue = rng:valueForUniqueID(uniqueID, seed)
				local rot = mat3Rotate(mat3Identity, randomValue * random_rotation, rotation)
				return rot
			end,

			dontRotateToFitBelowSurface = utils:getField(storageComponent, "rotate_to_fit_below_surface", {
				default = true,
				type = "boolean"
			}),
			
			placeObjectOffset = mj:mToP(utils:getVec3(storageComponent, "offset", {
				default = vec3(0.0, 0.0, 0.0)
			}))
		},

		maxCarryCount = utils:getField(carryCounts, "normal", {default=1}),
		maxCarryCountLimitedAbility = utils:getField(carryCounts, "limited_ability", {default=1}),
		maxCarryCountForRunning = utils:getField(carryCounts, "running", {default=1}),

		carryStackType = storageModule.stackTypes[utils:getField(carryComponent, "stack_type", {default="standard"})],
		carryType = storageModule.carryTypes[utils:getField(carryComponent, "carry_type", {default="standard"})],

		carryOffset = utils:getVec3(carryComponent, "offset", {
			default = vec3(0.0, 0.0, 0.0)
		}),

		carryRotation = mat3Rotate(mat3Identity,
			utils:getField(carryComponent, "rotation_constant", { default = 1}),
			utils:getVec3(carryComponent, "rotation", { default = vec3(0.0, 0.0, 0.0)})
		),
	}

	storageModule:addStorage(identifier, newStorage)
end

---------------------------------------------------------------------------------
-- Evolving Objects
---------------------------------------------------------------------------------

--- Generates evolving object definitions. For example an orange rotting into a rotten orange.
function objectManager:generateEvolvingObject(config)
	-- Modules
	local evolvingObjectModule = moduleManager:get("evolvingObject")
	local gameObjectModule =  moduleManager:get("gameObject")

	-- Setup
	local object_definition = config["hammerstone:object_definition"]
	local evolvingObjectComponent = object_definition.components["hammerstone:evolving_object"]
	local identifier = object_definition.description.identifier
	
	-- If the component doesn't exist, then simply don't register an evolving object.
	if evolvingObjectComponent == nil then
		return -- This is allowed	
	else
		log:schema("ddapi", "  " .. identifier)
	end

	-- TODO: Make this smart, and can handle day length OR year length.
	-- It claims it reads it as lua (schema), but it actually just multiplies it by days.
	local newEvolvingObject = {
		minTime = evolvingObjectModule.dayLength * evolvingObjectComponent.min_time,
		categoryIndex = evolvingObjectModule.categories[evolvingObjectComponent.category].index,
	}

	if evolvingObjectComponent.transform_to ~= nil then
		local function generateTransformToTable(transform_to)
			local newResource = {}
			for i, identifier in ipairs(transform_to) do
				table.insert(newResource, gameObjectModule.types[identifier].index)
			end
			return newResource
		end

		newEvolvingObject.toTypes = generateTransformToTable(evolvingObjectComponent.transform_to)
	end

	evolvingObjectModule:addEvolvingObject(identifier, newEvolvingObject)
end

---------------------------------------------------------------------------------
-- Game Object
---------------------------------------------------------------------------------

--- Registers an object into a storage.
-- @param identifier - The identifier of the object. e.g., hs:cake
-- @param componentData - The inner-table data for `hammerstone:storage`
function objectManager:registerObjectForStorage(identifier, componentData)

	if componentData == nil then
		return
	end

	-- Initialize this storage container, if this is the first item we're adding.
	local storageIdentifier = componentData.identifier
	if objectManager.objectsForStorage[storageIdentifier] == nil then
		objectManager.objectsForStorage[storageIdentifier] = {}
	end

	-- Insert the object identifier for this storage container
	table.insert(objectDB.objectsForStorage[storageIdentifier], identifier)
end

function objectManager:generateGameObjects()
	if runOnceGuard("gameObjects") then return end
	log:schema("ddapi", "\nGenerating Object definitions:")

	if objectDB.objectConfigs ~= nil and #objectDB.objectConfigs ~= 0 then
		for i, config in ipairs(objectDB.objectConfigs) do
			objectManager:generateGameObject(config)
		end
	else
		log:schema("ddapi", "  (none)")
	end
end

function objectManager:generateGameObject(config)
	if config == nil then
		log:schema("ddapi", "WARNING: Attempting to generate nil GameObject.")
		return
	end

	local object_definition = config["hammerstone:object_definition"]
	local description = object_definition["description"]
	local components = object_definition["components"]
	local objectComponent = components["hammerstone:object"]
	local identifier = description["identifier"]
	log:schema("ddapi", "  " .. identifier)

	local name = description["name"]
	local plural = description["plural"]
	local scale = objectComponent["scale"]
	local model = objectComponent["model"]
	local physics = objectComponent["physics"]
	local marker_positions = objectComponent["marker_positions"]
	
	-- Allow resource linking
	local resourceIdentifier = identifier
	local resourceLinkComponent = components["hammerstone:resource_link"]
	if resourceLinkComponent ~= nil then
		resourceIdentifier = resourceLinkComponent["identifier"]
	end

	-- If resource link doesn't exist, don't crash the game
	local resourceIndex = utils:getTypeIndex(moduleManager:get("resource").types, resourceIdentifier, "Resource")
	if resourceIndex == nil then return end

	-- TODO: toolUsages
	-- TODO: selectionGroupTypeIndexes
	-- TODO: Implement eatByProducts

	-- TODO: These ones are probably for a new component related to world placement.
	-- allowsAnyInitialRotation
	-- randomMaxScale = 1.5,
	-- randomShiftDownMin = -1.0,
	-- randomShiftUpMax = 0.5,
	local newObject = {
		name = name,
		plural = plural,
		modelName = model,
		scale = scale,
		hasPhysics = physics,
		resourceTypeIndex = resourceIndex,

		-- TODO: Implement marker positions
		markerPositions = {
			{
				worldOffset = vec3(mj:mToP(0.0), mj:mToP(0.3), mj:mToP(0.0))
			}
		}
	}

	-- Actually register the game object
	moduleManager:get("gameObject"):addGameObject(identifier, newObject)
end

---------------------------------------------------------------------------------
-- Craftable
---------------------------------------------------------------------------------

--- Generates recipe definitions based on the loaded config, and registers them.
function objectManager:generateRecipeDefinitions()
	if runOnceGuard("recipe") then return end
	log:schema("ddapi", "\nGenerating Recipe definitions:")

	if objectDB.recipeConfigs ~= nil and #objectDB.recipeConfigs ~= 0 then
		for i, config in ipairs(objectDB.recipeConfigs) do
			objectManager:generateRecipeDefinition(config)
		end
	else
		log:schema("ddapi", "  (none)")
	end
end

function objectManager:generateRecipeDefinition(config)

	if config == nil then
		log:schema("ddapi", "  Warning! Attempting to generate a recipe definition that is nil.")
		return
	end
	
	-- Definition
	local objectDefinition = config["hammerstone:recipe_definition"]
	local description = objectDefinition["description"]
	local identifier = description["identifier"]
	local components = objectDefinition["components"]

	-- Components
	local recipe = components["hammerstone:recipe"]
	local requirements = components["hammerstone:requirements"]
	local output = components["hammerstone:output"]
	local build_sequence = components["hammerstone:build_sequence"]

	log:schema("ddapi", "  " .. identifier)

	local required = {
		identifier = true,
		name = true,
		plural = true,
		summary = true,

		iconGameObjectType = true,
		classification = true,
		isFoodPreperation = false,
		
		skills = false,
		requiredCraftAreaGroups = false,
		requiredTools = false,

		outputObjectInfo = true,
		
		inProgressBuildModel = true,
		buildSequence = true,
		requiredResources = true,

		-- TODO: outputDisplayCount
		-- TODO: addGameObjectInfo
			-- modelName
			-- resourceTypeIndex
			-- toolUsages {}
	}

	local data = utils:compile(required, {

		-- Description
		identifier = utils:getField(description, "identifier", {
			notInTypeTable = moduleManager:get("craftable").types
		}),
		name = utils:getField(description, "name"),
		plural = utils:getField(description, "plural"),
		summary = utils:getField(description, "summary"),


		-- Recipe Component
		iconGameObjectType = utils:getField(recipe, "preview_object", {
			inTypeTable = moduleManager:get("gameObject").types
		}),
		classification = utils:getField(recipe, "classification", {
			inTypeTable = moduleManager:get("constructable").classifications -- Why is this crashing?
		}),
		isFoodPreperation = utils:getField(recipe, "isFoodPreparation", {
			type = "boolean"
		}),


		-- Output Component
		outputObjectInfo = {
			outputArraysByResourceObjectType = utils:getTable(output, "output_by_object", {
				with = function(tbl)
					local result = {}
					for _, value in pairs(tbl) do -- Loop through all output objects
						
						-- Return if input isn't a valid gameObject
						if utils:getTypeIndex(moduleManager:get("gameObject").types, value.input, "Game Object") == nil then return end

						-- Get the input's resource index
						local index = moduleManager:get("gameObject").types[value.input].index

						-- Convert from schema format to vanilla format
						-- If the predicate returns nil for any element, map returns nil
						-- In this case, log an error and return if any output item does not exist in gameObject.types
						result[index] = utils:map(value.output, function(e)
							return utils:getTypeIndex(moduleManager:get("gameObject").types, e, "Game Object")
						end)
					end
					return result
				end
			}),
		},


		-- Requirements Component
		skills = utils:getTable(requirements, "skills", {
			inTypeTable = moduleManager:get("skill").types,
			with = function(tbl)
				if #tbl > 0 then
					return {
						required = moduleManager:get("skill").types[tbl[1] ].index
					}
				end
			end
		}),
		disabledUntilAdditionalSkillTypeDiscovered = utils:getTable(requirements, "skills", {
			inTypeTable = moduleManager:get("skill").types,
			with = function(tbl)
				if #tbl > 1 then
					return moduleManager:get("skill").types[tbl[2] ].index
				end
			end
		}),
		requiredCraftAreaGroups = utils:getTable(requirements, "craft_area_groups", {
			map = function(e)
				return utils:getTypeIndex(moduleManager:get("craftAreaGroup").types, e, "Craft Area Group")
			end
		}),
		requiredTools = utils:getTable(requirements, "tools", {
			map = function(e)
				return utils:getTypeIndex(moduleManager:get("tool").types, e, "Tool")
			end
		}),


		-- Build Sequence Component
		inProgressBuildModel = utils:getField(build_sequence, "build_sequence_model"),
		buildSequence = utils:getTable(build_sequence, "build_sequence", {
			with = function(tbl)
				if not utils:isEmpty(tbl.steps) then
					-- If steps exist, we create a custom build sequence instead a standard one
					logNotImplemented("Custom Build Sequence") -- TODO: Implement steps
				else
					-- Cancel if action field doesn't exist
					if tbl.action == nil then
						return log:schema("ddapi", "    Missing Action Sequence")
					end

					-- Get the action sequence
					local sequence = utils:getTypeIndex(moduleManager:get("actionSequence").types, tbl.action, "Action Sequence")
					if sequence ~= nil then

						-- Cancel if a tool is stated but doesn't exist
						if tbl.tool ~= nil and #tbl.tool > 0 and utils:getTypeIndex(moduleManager:get("tool").types, tbl.tool, "Tool") == nil then
							return
						end

						-- Return the standard build sequence constructor
						return moduleManager:get("craftable"):createStandardBuildSequence(sequence, tbl.tool)
					end
				end
			end
		}),
		requiredResources = utils:getTable(build_sequence, "resource_sequence", {
			-- Runs for each item and replaces item with return result
			map = function(e)

				-- Get the resource
				local res = utils:getTypeIndex(moduleManager:get("resource").types, e.resource, "Resource")
				if (res == nil) then return end -- Cancel if resource does not exist

				-- Get the count
				local count = e.count or 1
				if (not utils:isType(count, "number")) then
					return log:schema("ddapi", "    Resource count for " .. e.resource .. " is not a number")
				end

				if e.action ~= nil then

					-- Return if action is invalid
					local actionType = utils:getTypeIndex(moduleManager:get("action").types, e.action.action_type, "Action")
					if (actionType == nil) then return end

					-- Return if duration is invalid
					local duration = e.action.duration
					if (not utils:isType(duration, "number")) then
						return log:schema("ddapi", "    Duration for " .. e.action.action_type .. " is not a number")
					end

					-- Return if duration without skill is invalid
					local durationWithoutSkill = e.action.duration_without_skill or duration
					if (not utils:isType(durationWithoutSkill, "number")) then
						return log:schema("ddapi", "    Duration without skill for " .. e.action.action_type .. " is not a number")
					end

					return {
						type = res,
						count = count,
						afterAction = {
							actionTypeIndex = actionType,
							duration = duration,
							durationWithoutSkill = durationWithoutSkill,
						}
					}
				end
				return {
					type = res,
					count = count,
				}
			end
		})
	})

	if data ~= nil then
		-- Add recipe
		moduleManager:get("craftable"):addCraftable(identifier, data)

		-- Add items in crafting panels
		for _, group in ipairs(data.requiredCraftAreaGroups) do
			local key = moduleManager:get("gameObject").typeIndexMap[moduleManager:get("craftAreaGroup").types[group].key]
			if objectManager.inspectCraftPanelData[key] == nil then
				objectManager.inspectCraftPanelData[key] = {}
			end
			table.insert(objectManager.inspectCraftPanelData[key], moduleManager:get("constructable").types[identifier].index)
		end
	end
end

---------------------------------------------------------------------------------
-- Material
---------------------------------------------------------------------------------

--- Generates material definitions based on the loaded config, and registers them.
function objectManager:generateMaterialDefinitions()
	if runOnceGuard("material") then return end
	log:schema("ddapi", "\nGenerating Material definitions:")

	if objectDB.materialConfigs ~= nil and #objectDB.materialConfigs ~= 0 then
		for i, config in ipairs(objectDB.materialConfigs) do
			objectManager:generateMaterialDefinition(config)
		end
	else
		log:schema("ddapi", "  (none)")
	end
end

function objectManager:generateMaterialDefinition(config)
	local materialDefinition = config["hammerstone:material_definition"]
	local materials = materialDefinition["materials"]

	for _, mat in pairs(materials) do

		log:schema("ddapi", "  " .. mat["identifier"])

		local required = {
			identifier = true,
			color = true,
			roughness = true,
			metal = false,
		}

		local data = utils:compile(required, {

			identifier = utils:getField(mat, "identifier", {
				notInTypeTable = moduleManager:get("material").types
			}),

			color = utils:getVec3(mat, "color"),
			
			roughness = utils:getField(mat, "roughness", {
				type = "number"
			}),

			metal = utils:getField(mat, "metal", {
				type = "number"
			})
		})

		if data ~= nil then
			moduleManager:get("material"):addMaterial(data.identifier, data.color, data.roughness, data.metal)
		end
	end
end

---------------------------------------------------------------------------------
-- Skill
---------------------------------------------------------------------------------

--- Generates skill definitions based on the loaded config, and registers them.
function objectManager:generateSkillDefinitions()
	if runOnceGuard("skill") then return end
	log:schema("ddapi", "\nGenerating Skill definitions:")

	if objectDB.skillConfigs ~= nil and #objectDB.skillConfigs ~= 0 then
		for i, config in ipairs(objectDB.skillConfigs) do
			objectManager:generateSkillDefinition(config)
		end
	else
		log:schema("ddapi", "  (none)")
	end
end

function objectManager:generateSkillDefinition(config)

	if config == nil then
		log:schema("ddapi", "  Warning! Attempting to generate a skill definition that is nil.")
		return
	end
	
	local skillDefinition = config["hammerstone:skill_definition"]
	local skills = skillDefinition["skills"]

	for _, s in pairs(skills) do

		local desc = s["description"]
		local skil = s["skill"]

		log:schema("ddapi", "  " .. desc["identifier"])

		local required = {
			identifier = true,
			name = true,
			description = true,
			icon = true,

			row = true,
			column = true,
			requiredSkillTypes = false,
			startLearned = false,
			partialCapacityWithLimitedGeneralAbility = false,
		}

		local data = utils:compile(required, {

			identifier = utils:getField(desc, "identifier", {
				notInTypeTable = moduleManager:get("skill").types
			}),
			name = utils:getField(desc, "name"),
			description = utils:getField(desc, "description"),
			icon = utils:getField(desc, "icon"),

			row = utils:getField(skil, "row", {
				type = "number"
			}),
			column = utils:getField(skil, "column", {
				type = "number"
			}),
			requiredSkillTypes = utils:getTable(skil, "requiredSkills", {
				-- Make sure each skill exists and transform skill name to index
				map = function(e) return utils:getTypeIndex(moduleManager:get("skill").types, e, "Skill") end
			}),
			startLearned = utils:getField(skil, "startLearned", {
				type = "boolean"
			}),
			partialCapacityWithLimitedGeneralAbility = utils:getField(skil, "impactedByLimitedGeneralAbility", {
				type = "boolean"
			}),
		})

		if data ~= nil then
			moduleManager:get("skill"):addSkill(data.identifier, data)
		end
	end
end

return objectManager