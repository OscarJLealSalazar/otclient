HOTKEY_USE = nil
HOTKEY_USEONSELF = 1
HOTKEY_USEONTARGET = 2
HOTKEY_USEWITH = 3

local maxSlots = 60
-- one fixed bar plus a few extra ones the player can show and hide at will
local ACTION_BAR_COUNT = 5
local EXTRA_BAR_WIDTH = 480
local SWAP_SLOT_ID = 'slotSwapTemp'

actionBars = {}
actionBar = nil
actionBarPanel = nil
extraBarsVisible = false
local applyingExtraBars = false
-- while a whole bar set is being restored the per-slot helpers must not rebind
-- every hotkey again, that would be quadratic on the number of slots
local bulkLoading = false
bottomPanel = nil
slotToEdit = nil
spellAssignWindow = nil
spellsPanel = nil
textAssignWindow = nil
objectAssignWindow = nil
mouseGrabberWidget = nil
actionRadioGroup = nil
editHotkeyWindow = nil
missedSlotToEdit = nil
itemDragRetry = nil
slotReassign = nil
lastHotkeyTime = 0
cooldown = {}
groupCooldown = {}

local ProgressCallback = {
    update = 1,
    finish = 2
}

function init()
    bottomPanel = modules.game_interface.getBottomPanel()
    actionBar = g_ui.loadUI('game_actionbar', bottomPanel)
    actionBarPanel = actionBar:getChildById('actionBarPanel')

    actionBars = { {
        window = actionBar,
        panel = actionBarPanel,
        index = 1,
        fixed = true
    } }
    createExtraBars()

    g_keyboard.bindKeyDown('Alt+B', toggleExtraBars)

    mouseGrabberWidget = g_ui.createWidget('UIWidget')
    mouseGrabberWidget:setVisible(false)
    mouseGrabberWidget:setFocusable(false)
    mouseGrabberWidget.onMouseRelease = onChooseItemMouseRelease

    local console = modules.game_console.consolePanel
    if console then
        console:addAnchor(AnchorTop, actionBar:getId(), AnchorBottom)
    end

    if g_game.isOnline() then
        addEvent(function()
            setupActionBar()
            loadActionBar()
        end)
    end

    connect(g_game, {
        onGameStart = online,
        onGameEnd = offline,
        onSpellGroupCooldown = onSpellGroupCooldown,
        onSpellCooldown = onSpellCooldown
    })

end

function terminate()
    g_keyboard.unbindKeyDown('Alt+B')

    for i = #actionBars, 1, -1 do
        local bar = actionBars[i].window
        if bar and not bar:isDestroyed() then
            bar:destroy()
        end
    end
    actionBars = {}
    actionBar = nil
    actionBarPanel = nil

    mouseGrabberWidget:destroy()
    disconnect(g_game, {
        onGameStart = online,
        onGameEnd = offline,
        onSpellGroupCooldown = onSpellGroupCooldown,
        onSpellCooldown = onSpellCooldown
    })
    if spellAssignWindow then
        closeSpellAssignWindow()
    end
    if objectAssignWindow then
        closeObjectAssignWindow()
    end
    if textAssignWindow then
        closeTextAssignWindow()
    end
    if editHotkeyWindow then
        closeEditHotkeyWindow()
    end
    if spellsPanel then
        disconnect(spellsPanel, {
            onChildFocusChange = function(self, focusedChild)
                if focusedChild == nil then
                    return
                end
                updatePreviewSpell(focusedChild)
            end
        })
    end

    local console = modules.game_console.consolePanel
    if console then
        console:removeAnchor(AnchorTop)
        console:fill('parent')
    end
end

function online()
    for _, bar in ipairs(actionBars) do
        bar.panel:destroyChildren()
    end
    addEvent(function()
        setupActionBar()
        loadActionBar()
    end)
end

function offline()
    saveActionBar()
    unbindHotkeys()
end

-- ---------------------------------------------------------------------------
-- bars
-- ---------------------------------------------------------------------------

-- Slot ids stay unique across every bar: the first bar owns slot1..slot60, the
-- second one slot61..slot120 and so on, so old settings keep loading into the
-- fixed bar untouched.
local function slotIdAt(barIndex, slotIndex)
    return 'slot' .. ((barIndex - 1) * maxSlots + slotIndex)
end

function getBars()
    return actionBars
end

function getFixedBar()
    return actionBar
end

function getSlotById(slotId)
    if not slotId then
        return nil
    end

    for _, bar in ipairs(actionBars) do
        local slot = bar.panel:getChildById(slotId)
        if slot then
            return slot
        end
    end
    return nil
end

function getAllSlots()
    local slots = {}
    for _, bar in ipairs(actionBars) do
        for _, slot in ipairs(bar.panel:getChildren()) do
            table.insert(slots, slot)
        end
    end
    return slots
end

-- Lets the player drag an extra bar anywhere on the screen using the grip on
-- its left edge, so the slots themselves keep their own drag and drop.
local function setupBarDragging(bar)
    local grip = bar:getChildById('dragGrip')
    grip:setVisible(true)
    grip:setWidth(10)
    grip:setDraggable(true)

    grip.onDragEnter = function(widget, mousePos)
        local pos = bar:getPosition()
        widget.movingReference = {
            x = mousePos.x - pos.x,
            y = mousePos.y - pos.y
        }
        return true
    end

    grip.onDragMove = function(widget, mousePos, mouseMoved)
        if not widget.movingReference then
            return false
        end
        bar:setPosition({
            x = mousePos.x - widget.movingReference.x,
            y = mousePos.y - widget.movingReference.y
        })
        return true
    end

    grip.onDragLeave = function(widget)
        widget.movingReference = nil
        keepBarOnScreen(bar)
        saveBarPositions()
        return true
    end
end

function keepBarOnScreen(bar)
    local parent = bar:getParent()
    if not parent then
        return
    end

    local area = parent:getRect()
    if area.width <= 0 or area.height <= 0 then
        return
    end

    bar:setPosition({
        x = math.max(area.x, math.min(bar:getX(), area.x + area.width - bar:getWidth())),
        y = math.max(area.y, math.min(bar:getY(), area.y + area.height - bar:getHeight()))
    })
end

-- Stacks the extra bars upwards from just above the bottom panel, so they never
-- open on top of the console or of the fixed bar.
local function defaultBarPosition(bar, index)
    local parent = bar:getParent()
    local area = parent:getRect()

    local reserved = 0
    if bottomPanel then
        reserved = bottomPanel:getHeight()
    end

    local step = bar:getHeight() + 4
    return {
        x = area.x + math.max(0, math.floor((area.width - bar:getWidth()) / 2)),
        y = area.y + math.max(0, area.height - reserved - 10 - (index - 1) * step)
    }
end

function createExtraBars()
    local rootPanel = modules.game_interface.getRootPanel()

    for i = 2, ACTION_BAR_COUNT do
        local bar = g_ui.createWidget('ActionBarWindow', rootPanel)
        bar:setId('actionBar' .. i)
        bar:setWidth(EXTRA_BAR_WIDTH)
        bar:setVisible(false)
        setupBarDragging(bar)

        table.insert(actionBars, {
            window = bar,
            panel = bar:getChildById('actionBarPanel'),
            index = i,
            fixed = false
        })
    end
end

function areExtraBarsVisible()
    return extraBarsVisible
end

function setExtraBarsVisible(visible)
    if applyingExtraBars then
        return
    end

    applyingExtraBars = true
    visible = visible and true or false
    extraBarsVisible = visible

    for _, bar in ipairs(actionBars) do
        if not bar.fixed then
            bar.window:setVisible(visible)
            if visible then
                if bar.window:getX() == 0 and bar.window:getY() == 0 then
                    bar.window:setPosition(defaultBarPosition(bar.window, bar.index))
                end
                keepBarOnScreen(bar.window)
                bar.window:raise()
            end
        end
    end

    if modules.client_options then
        modules.client_options.setOption('showExtraActionBars', visible)
    end

    applyingExtraBars = false
end

function toggleExtraBars()
    setExtraBarsVisible(not extraBarsVisible)
end

function saveBarPositions()
    local settings = g_settings.getNode('game_actionbar_bars') or {}
    local char = g_game.getCharacterName()
    if not char or #char == 0 then
        return
    end

    settings[char] = {}
    for _, bar in ipairs(actionBars) do
        if not bar.fixed then
            settings[char][bar.window:getId()] = {
                position = pointtostring(bar.window:getPosition()),
                width = bar.window:getWidth()
            }
        end
    end

    g_settings.setNode('game_actionbar_bars', settings)
end

function loadBarPositions()
    local settings = g_settings.getNode('game_actionbar_bars')
    local char = g_game.getCharacterName()
    if not settings or not char or not settings[char] then
        return
    end

    for _, bar in ipairs(actionBars) do
        if not bar.fixed then
            local barSettings = settings[char][bar.window:getId()]
            if barSettings then
                if barSettings.width then
                    bar.window:setWidth(barSettings.width)
                end
                if barSettings.position then
                    bar.window:setPosition(topoint(barSettings.position))
                end
                keepBarOnScreen(bar.window)
            end
        end
    end
end

function copySlot(fromSlotId, toSlotId, visible)
    local fromSlot = getSlotById(fromSlotId)
    local tmpslot = getSlotById(toSlotId)
    if not tmpslot then
        tmpslot = g_ui.createWidget('ActionSlot', actionBarPanel)
        tmpslot:setId(toSlotId)
    end
    if not fromSlot then
        return
    end
    tmpslot:setVisible(visible)
    local tmptext = not fromSlot.text
    local tmpid = not fromSlot.itemId
    local tmpwords = not fromSlot.words
    local imageSource = fromSlot:getImageSource()
    local imageClip = fromSlot:getImageClip()
    local imgsrcbool = not imageSource
    local imgclipbool = not imageClip
    imageSource = (imgsrcbool or (tmptext and tmpid and tmpwords)) and '/images/game/actionbar/slot-actionbar' or
                      imageSource
    imageClip = imgclipbool and '0 0 0 0' or imageClip
    tmpslot:setImageSource(imageSource)
    tmpslot:setImageClip(imageClip)
    local tmpItem = fromSlot:getItem()
    if tmpItem then
        tmpslot:setItem(tmpItem)
    else
        tmpslot:setItem(nil)
    end
    tmpslot:setText(fromSlot:getText())
    tmpslot.autoSend = fromSlot.autoSend
    tmpslot.itemId = fromSlot.itemId
    tmpslot.subType = fromSlot.subType
    tmpslot.words = fromSlot.words
    tmpslot.text = fromSlot.text
    tmpslot.parameter = fromSlot.parameter
    tmpslot.useType = fromSlot.useType
    tmpslot:getChildById('text'):setText(fromSlot:getChildById('text'):getText())
    tmpslot:setTooltip(fromSlot:getTooltip())
end

function onDropFunc(slotId)
    if slotReassign then
        local fromSlotId = slotToEdit
        local toSlotId = slotId
        local fromSlot = getSlotById(fromSlotId)
        local toSlot = getSlotById(toSlotId)
        if fromSlot and toSlot then
            local tmpslotid = SWAP_SLOT_ID
            copySlot(fromSlotId, tmpslotid, false)
            copySlot(toSlotId, fromSlotId, true)
            copySlot(tmpslotid, toSlotId, true)
            clearSlotById(tmpslotid)
        end
        slotReassign = nil
        slotToEdit = nil
    end
    slotToEdit = slotId
    if itemDragRetry and missedSlotToEdit then -- first drag doesn't register slotToEdit
        local widget1 = missedSlotToEdit[1]
        local mousePos1 = missedSlotToEdit[2]
        local item1 = missedSlotToEdit[3]
        if widget1 and mousePos1 and item1 then
            onChooseItemByDrag(widget1, mousePos1, item1)
        end
        itemDragRetry = nil
        missedSlotToEdit = nil
    end
    setupHotkeys()
end

function setupActionBar()
    for _, bar in ipairs(actionBars) do
        for i = 1, maxSlots do
            local slotId = slotIdAt(bar.index, i)
            local slot = g_ui.createWidget('ActionSlot', bar.panel)
            slot:setId(slotId)
            slot:setVisible(true)
            slot.itemId = nil
            slot.subType = nil
            slot.words = nil
            slot.text = nil
            slot.useType = nil
            g_mouse.bindPress(slot, function()
                slotToEdit = slotId
            end, MouseLeftButton)
            g_mouse.bindPress(slot, function()
                createMenu(slotId)
            end, MouseRightButton)
            g_mouse.bindOnDrop(slot, function()
                if slotToEdit == slotId then
                    slotReassign = slotId
                end
                onDropFunc(slotId)
            end)
            if i == 1 then
                slot:addAnchor(AnchorLeft, 'parent', AnchorLeft)
            end
        end
    end

    loadBarPositions()

    -- client_options may have been restored before this module was loaded
    if modules.client_options then
        setExtraBarsVisible(modules.client_options.getOption('showExtraActionBars'))
    end
end

function createMenu(slotId)
    local menu = g_ui.createWidget('PopupMenu')
    slotToEdit = slotId
    menu:addOption('Assign Spell', function()
        openSpellAssignWindow()
    end)
    menu:addOption('Assign Object', function()
        startChooseItem()
        openObjectAssignWindow()
    end)
    menu:addOption('Assign Text', function()
        openTextAssignWindow()
    end)
    menu:addOption('Edit Hotkey', function()
        openEditHotkeyWindow()
    end)
    local actionSlot = getSlotById(slotToEdit)
    if actionSlot.itemId or actionSlot.words or actionSlot.text or actionSlot.useType or actionSlot.hotkey then
        menu:addOption('Clear Slot', function()
            clearSlot()
            clearHotkey()
        end)
    end
    menu:display()
end

function openSpellAssignWindow()
    spellAssignWindow = g_ui.loadUI('assign_spell', g_ui.getRootWidget())
    spellsPanel = spellAssignWindow:getChildById('spellsPanel')
    addEvent(function()
        initializeSpelllist()
    end)
    spellAssignWindow:raise()
    spellAssignWindow:focus()
    spellAssignWindow:getChildById('filterTextEdit'):focus()
    modules.game_hotkeys.enableHotkeys(false)
end

function closeSpellAssignWindow()
    spellAssignWindow:destroy()
    spellAssignWindow = nil
    spellsPanel = nil
    modules.game_hotkeys.enableHotkeys(true)
end

function initializeSpelllist()
    g_keyboard.bindKeyPress('Down', function()
        spellsPanel:focusNextChild(KeyboardFocusReason)
    end, spellsPanel:getParent())
    g_keyboard.bindKeyPress('Up', function()
        spellsPanel:focusPreviousChild(KeyboardFocusReason)
    end, spellsPanel:getParent())

    for spellProfile, _ in pairs(SpelllistSettings) do
        for i = 1, #SpelllistSettings[spellProfile].spellOrder do
            local spell = SpelllistSettings[spellProfile].spellOrder[i]
            local info = SpellInfo[spellProfile][spell]
            if info then
                local tmpLabel = g_ui.createWidget('SpellListLabel', spellsPanel)
                tmpLabel:setId(spell)
                tmpLabel:setText(spell .. '\n\'' .. info.words .. '\'')
                tmpLabel:setPhantom(false)
                tmpLabel.defaultHeight = tmpLabel:getHeight()
                tmpLabel.words = info.words:lower()
                tmpLabel.name = spell:lower()

                local iconId = tonumber(info.icon)
                if not iconId and SpellIcons[info.icon] then
                    iconId = SpellIcons[info.icon][1]
                end

                tmpLabel:setHeight(SpelllistSettings[spellProfile].iconSize.height + 4)
                tmpLabel:setTextOffset(topoint((SpelllistSettings[spellProfile].iconSize.width + 10) .. ' ' ..
                                                   (SpelllistSettings[spellProfile].iconSize.height - 32) / 2 + 3))
                tmpLabel:setImageSource(SpelllistSettings[spellProfile].iconFile)
                tmpLabel:setImageClip(Spells.getImageClip(iconId, spellProfile))
                tmpLabel:setImageSize(tosize(SpelllistSettings[spellProfile].iconSize.width .. ' ' ..
                                                 SpelllistSettings[spellProfile].iconSize.height))
            end
        end
    end

    for v, k in ipairs(spellsPanel:getChildren()) do
        if k:isVisible() then
            spellsPanel:focusChild(k, KeyboardFocusReason)
            updatePreviewSpell(k)
            break
        end
    end
    connect(spellsPanel, {
        onChildFocusChange = function(self, focusedChild)
            if focusedChild == nil then
                return
            end
            updatePreviewSpell(focusedChild)
        end
    })
end

function updatePreviewSpell(focusedChild)
    local spellName = focusedChild:getId()
    iconId = tonumber(Spells.getClientId(spellName))
    local spell = Spells.getSpellByName(spellName)
    local profile = Spells.getSpellProfileByName(spellName)
    spellsPanel:getParent():getChildById('previewSpell'):setImageSource(SpelllistSettings[profile].iconFile)
    spellsPanel:getParent():getChildById('previewSpell'):setImageClip(Spells.getImageClip(iconId, profile))
    spellsPanel:getParent():getChildById('previewSpellName'):setText(spellName)
    spellsPanel:getParent():getChildById('previewSpellWords'):setText('\'' .. spell.words .. '\'')
    if spell.parameter then
        spellAssignWindow:getChildById('parameterTextEdit'):enable()
    else
        spellAssignWindow:getChildById('parameterTextEdit'):disable()
    end
end

function spellAssignAccept()
    clearSlot()
    local focusedChild = spellsPanel:getFocusedChild()
    if not focusedChild then
        return
    end
    local spellName = focusedChild:getId()
    iconId = tonumber(Spells.getClientId(spellName))
    local spell = Spells.getSpellByName(spellName)
    local profile = Spells.getSpellProfileByName(spellName)
    local slot = getSlotById(slotToEdit)
    slot:setImageSource(Spells.getIconFileByProfile(profile))
    slot:setImageClip(Spells.getImageClip(iconId, profile))
    slot.words = spell.words
    slot.itemId = 469
    slot:setItemId(469)
    if spell.parameter then
        slot.parameter = spellAssignWindow:getChildById('parameterTextEdit'):getText():gsub('"', '')
    else
        slot.parameter = nil
    end
    closeSpellAssignWindow()
    setupHotkeys()
end

function clearSlot()
    local slot = getSlotById(slotToEdit)
    slot:setImageSource('/images/game/actionbar/slot-actionbar')
    slot:setImageClip('0 0 0 0')
    slot:clearItem()
    slot:setText('')
    slot.itemId = nil
    slot.subType = nil
    slot.words = nil
    slot.text = nil
    slot.useType = nil
    slot:getChildById('text'):setText('')
    slot:setTooltip('')
end

function clearSlotById(slotId)
    local slot = getSlotById(slotId)
    slot:setImageSource('/images/game/actionbar/slot-actionbar')
    slot:setImageClip('0 0 0 0')
    slot:clearItem()
    slot:setText('')
    slot.itemId = nil
    slot.subType = nil
    slot.words = nil
    slot.text = nil
    slot.useType = nil
    slot:getChildById('text'):setText('')
    slot:setTooltip('')
end

function clearHotkey()
    local slot = getSlotById(slotToEdit)
    slot.hotkey = nil
    slot:getChildById('key'):setText('')
end

function openTextAssignWindow()
    textAssignWindow = g_ui.loadUI('assign_text', g_ui.getRootWidget())
    textAssignWindow:raise()
    textAssignWindow:focus()
    modules.game_hotkeys.enableHotkeys(false)
end

function closeTextAssignWindow()
    textAssignWindow:destroy()
    textAssignWindow = nil
    modules.game_hotkeys.enableHotkeys(true)
end

function textAssignAccept()
    local text = textAssignWindow:getChildById('textToSendTextEdit'):getText()
    if text == '' then
        return
    end
    local checkForParameter = text:split(' "')
    local name, parameter = nil, nil
    if #checkForParameter == 2 then
        name = checkForParameter[1]
        parameter = checkForParameter[2]
    else
        name = text
    end

    local spell, profile, spellName = Spells.getSpellByWords(name)

    local slot = getSlotById(slotToEdit)
    if spellName then
        iconId = tonumber(Spells.getClientId(spellName))
        clearSlot()
        slot:setImageSource(Spells.getIconFileByProfile(profile))
        slot:setImageClip(Spells.getImageClip(iconId, profile))
        slot.words = spell.words
        slot.itemId = 469
        slot:setItemId(469)
        if parameter and spell.parameter then
            slot.parameter = parameter
        else
            slot.parameter = nil
        end
    else
        clearSlot()
        slot:getChildById('text'):setText(text)
        while slot:getChildById('text'):getTextSize().height > 30 do
            local subString = slot:getChildById('text'):getText()
            subString = string.sub(subString, 1, #subString - 1)
            slot:getChildById('text'):setText(subString)
        end
        slot:setImageSource('/images/game/actionbar/item-background')
        slot.text = text
        slot.itemId = 469
        slot:setItemId(469)
        slot.autoSend = textAssignWindow:recursiveGetChildById('sendAutomaticallyCheckBox'):isChecked()
        slot:setTooltip(slot.text)
        setupHotkeys()
    end
    closeTextAssignWindow()
end

function openObjectAssignWindow()
    if objectAssignWindow ~= nil then
        objectAssignWindow:destroy()
    end
    objectAssignWindow = g_ui.loadUI('assign_object', g_ui.getRootWidget())
    actionRadioGroup = UIRadioGroup.create()
    actionRadioGroup:addWidget(objectAssignWindow:getChildById('useOnYourselfCheckbox'))
    actionRadioGroup:addWidget(objectAssignWindow:getChildById('useOnTargetCheckbox'))
    actionRadioGroup:addWidget(objectAssignWindow:getChildById('useWithCrosshairCheckbox'))
    actionRadioGroup:addWidget(objectAssignWindow:getChildById('equipCheckbox'))
    actionRadioGroup:addWidget(objectAssignWindow:getChildById('useCheckbox'))
    objectAssignWindow:setVisible(false)
end

function closeObjectAssignWindow()
    objectAssignWindow:destroy()
    objectAssignWindow = nil
    actionRadioGroup = nil
    modules.game_hotkeys.enableHotkeys(true)
end

function startChooseItem()
    if g_ui.isMouseGrabbed() then
        return
    end
    mouseGrabberWidget:grabMouse()
    g_mouse.pushCursor('target')
end

function objectAssignAccept()
    clearSlot()
    local item = objectAssignWindow:getChildById('previewItem'):getItem()
    if not item then
        return
    end
    local slot = getSlotById(slotToEdit)
    slot:setItem(item)
    slot:setImageSource('/images/game/actionbar/item-background')
    slot:setBorderWidth(0)
    slot.itemId = item:getId()
    if item:isFluidContainer() then
        slot.subType = item:getSubType()
    end
    if objectAssignWindow:getChildById('equipCheckbox'):isChecked() then
        slot.useType = 'equip'
    elseif objectAssignWindow:getChildById('useCheckbox'):isChecked() then
        slot.useType = 'use'
    elseif objectAssignWindow:getChildById('useOnYourselfCheckbox'):isChecked() then
        slot.useType = 'useOnSelf'
    elseif objectAssignWindow:getChildById('useOnTargetCheckbox'):isChecked() then
        slot.useType = 'useOnTarget'
    elseif objectAssignWindow:getChildById('useWithCrosshairCheckbox'):isChecked() then
        slot.useType = 'useWith'
    end
    setupHotkeys()
    closeObjectAssignWindow()
end

function onChooseItemMouseRelease(self, mousePosition, mouseButton)
    local item = nil
    if mouseButton == MouseLeftButton then
        local clickedWidget = modules.game_interface.getRootPanel():recursiveGetChildByPos(mousePosition, false)
        if clickedWidget then
            if clickedWidget:getClassName() == 'UIItem' and not clickedWidget:isVirtual() then
                item = clickedWidget:getItem()
            end
        end
    end

    if item and item:getPosition().x == 65535 and slotToEdit then
        objectAssignWindow:getChildById('previewItem'):setItemId(item:getId())
        objectAssignWindow:getChildById('previewItem'):setItemCount(1)
        objectAssignWindow:getChildById('equipCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useOnYourselfCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useOnTargetCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useWithCrosshairCheckbox'):setEnabled(false)
        if item:getClothSlot() > 0 then
            objectAssignWindow:getChildById('equipCheckbox'):setEnabled(true)
            if item:isMultiUse() then
                objectAssignWindow:getChildById('useOnYourselfCheckbox'):setEnabled(true)
                objectAssignWindow:getChildById('useOnTargetCheckbox'):setEnabled(true)
                objectAssignWindow:getChildById('useWithCrosshairCheckbox'):setEnabled(true)
            else
                objectAssignWindow:getChildById('useCheckbox'):setEnabled(true)
            end
            actionRadioGroup:selectWidget(objectAssignWindow:getChildById('equipCheckbox'))
        elseif item:isMultiUse() then
            objectAssignWindow:getChildById('useOnYourselfCheckbox'):setEnabled(true)
            objectAssignWindow:getChildById('useOnTargetCheckbox'):setEnabled(true)
            objectAssignWindow:getChildById('useWithCrosshairCheckbox'):setEnabled(true)
            objectAssignWindow:getChildById('equipCheckbox'):setEnabled(true)
            actionRadioGroup:selectWidget(objectAssignWindow:getChildById('useOnYourselfCheckbox'))
        else
            objectAssignWindow:getChildById('useCheckbox'):setEnabled(true)
            actionRadioGroup:selectWidget(objectAssignWindow:getChildById('useCheckbox'))
        end
        if not objectAssignWindow:isVisible() then
            objectAssignWindow:show()
        end
        objectAssignWindow:raise()
        objectAssignWindow:focus()
    end
    g_mouse.popCursor('target')
    self:ungrabMouse()
    return true
end

function onChooseItemByDrag(self, mousePosition, item)
    if item and item:getPosition().x == 65535 and slotToEdit then
        openObjectAssignWindow()
        objectAssignWindow:getChildById('previewItem'):setItemId(item:getId())
        objectAssignWindow:getChildById('previewItem'):setItemCount(1)
        objectAssignWindow:getChildById('equipCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useOnYourselfCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useOnTargetCheckbox'):setEnabled(false)
        objectAssignWindow:getChildById('useWithCrosshairCheckbox'):setEnabled(false)
        if item:getClothSlot() > 0 then
            objectAssignWindow:getChildById('equipCheckbox'):setEnabled(true)
            if item:isMultiUse() then
                objectAssignWindow:getChildById('useOnYourselfCheckbox'):setEnabled(true)
                objectAssignWindow:getChildById('useOnTargetCheckbox'):setEnabled(true)
                objectAssignWindow:getChildById('useWithCrosshairCheckbox'):setEnabled(true)
            else
                objectAssignWindow:getChildById('useCheckbox'):setEnabled(true)
            end
            actionRadioGroup:selectWidget(objectAssignWindow:getChildById('equipCheckbox'))
        elseif item:isMultiUse() then
            objectAssignWindow:getChildById('useOnYourselfCheckbox'):setEnabled(true)
            objectAssignWindow:getChildById('useOnTargetCheckbox'):setEnabled(true)
            objectAssignWindow:getChildById('useWithCrosshairCheckbox'):setEnabled(true)
            objectAssignWindow:getChildById('equipCheckbox'):setEnabled(true)
            actionRadioGroup:selectWidget(objectAssignWindow:getChildById('useOnYourselfCheckbox'))
        else
            objectAssignWindow:getChildById('useCheckbox'):setEnabled(true)
            actionRadioGroup:selectWidget(objectAssignWindow:getChildById('useCheckbox'))
        end
        if not objectAssignWindow:isVisible() then
            objectAssignWindow:show()
        end
        objectAssignWindow:raise()
        objectAssignWindow:focus()
    elseif not slotToEdit then
        itemDragRetry = true
        missedSlotToEdit = {self, mousePosition, item}
    end
end

function onDragReassign(self, item)
    slotReassign = self
end

function openEditHotkeyWindow()
    editHotkeyWindow = g_ui.loadUI('edit_hotkey', g_ui.getRootWidget())
    editHotkeyWindow:grabKeyboard()

    local comboLabel = editHotkeyWindow:recursiveGetChildById('comboPreview')
    comboLabel.keyCombo = ''
    editHotkeyWindow.onKeyDown = hotkeyCapture
    editHotkeyWindow:raise()
    editHotkeyWindow:focus()
    modules.game_hotkeys.enableHotkeys(false)
end

function closeEditHotkeyWindow()
    editHotkeyWindow:destroy()
    editHotkeyWindow = nil
    modules.game_hotkeys.enableHotkeys(true)
end

function unbindHotkeys()
    for v, slot in pairs(getAllSlots()) do
        if slot.hotkey and slot.hotkey ~= '' then
            g_keyboard.unbindKeyPress(slot.hotkey)
        end
    end
end

function setupHotkeys()
    if bulkLoading then
        return
    end

    unbindHotkeys()
    for v, slot in pairs(getAllSlots()) do
        slot.onMouseRelease = function()
            if g_clock.millis() - lastHotkeyTime < modules.client_options.getOption('hotkeyDelay') then
                return
            end

            lastHotkeyTime = g_clock.millis()
            if slot.itemId and slot.useType then
                if slot.useType == 'use' then
                    modules.game_hotkeys.executeHotkeyItem(HOTKEY_USE, slot.itemId, slot.subType)
                elseif slot.useType == 'useOnTarget' then
                    modules.game_hotkeys.executeHotkeyItem(HOTKEY_USEONTARGET, slot.itemId, slot.subType)
                elseif slot.useType == 'useWith' then
                    modules.game_hotkeys.executeHotkeyItem(HOTKEY_USEWITH, slot.itemId, slot.subType)
                elseif slot.useType == 'useOnSelf' then
                    modules.game_hotkeys.executeHotkeyItem(HOTKEY_USEONSELF, slot.itemId, slot.subType)
                elseif slot.useType == 'equip' then
                    local item = g_game.findPlayerItem(slot.itemId, -1)
                    if item then
                        g_game.equipItem(item)
                    end
                end
            elseif slot.words then
                if slot.parameter and slot.parameter ~= '' then
                    g_game.talk(slot.words .. ' "' .. slot.parameter)
                else
                    g_game.talk(slot.words)
                end
            elseif slot.text then
                if slot.autoSend then
                    g_game.talk(slot.text)
                else
                    if not modules.game_console.isChatEnabled() then
                        modules.game_console.switchChatOnCall()
                    end
                    modules.game_console.setTextEditText(slot.text)
                end
            end
        end

        if slot.hotkey and slot.hotkey ~= '' then
            g_keyboard.bindKeyPress(slot.hotkey, function()
                if not modules.game_hotkeys.canPerformKeyCombo(slot.hotkey) then
                    return
                end
                if g_clock.millis() - lastHotkeyTime < modules.client_options.getOption('hotkeyDelay') then
                    return
                end

                lastHotkeyTime = g_clock.millis()
                if slot.itemId and slot.useType then
                    if slot.useType == 'use' then
                        modules.game_hotkeys.executeHotkeyItem(HOTKEY_USE, slot.itemId, slot.subType)
                    elseif slot.useType == 'useOnTarget' then
                        modules.game_hotkeys.executeHotkeyItem(HOTKEY_USEONTARGET, slot.itemId, slot.subType)
                    elseif slot.useType == 'useWith' then
                        modules.game_hotkeys.executeHotkeyItem(HOTKEY_USEWITH, slot.itemId, slot.subType)
                    elseif slot.useType == 'useOnSelf' then
                        modules.game_hotkeys.executeHotkeyItem(HOTKEY_USEONSELF, slot.itemId, slot.subType)
                    elseif slot.useType == 'equip' then
                        local item = g_game.findPlayerItem(slot.itemId, -1)
                        if item then
                            g_game.equipItem(item)
                        end
                    end
                elseif slot.words then
                    if slot.parameter and slot.parameter ~= '' then
                        g_game.talk(slot.words .. ' "' .. slot.parameter)
                    else
                        g_game.talk(slot.words)
                    end
                elseif slot.text then
                    if slot.autoSend then
                        modules.game_console.sendMessage(slot.text)
                    else
                        scheduleEvent(function()
                            if not modules.game_console.isChatEnabled() then
                                modules.game_console.switchChatOnCall()
                            end
                            modules.game_console.setTextEditText(slot.text)
                        end, 1)
                    end
                end
            end)
        end
    end
end

function checkHotkey(hotkey)
    for v, k in pairs(getAllSlots()) do
        if k.hotkey == hotkey then
            return true
        end
    end
end

function hotkeyCapture(assignWindow, keyCode, keyboardModifiers)
    local hotkeyAlreadyUsed = false
    assignWindow:raise()
    assignWindow:focus()
    local keyCombo = determineKeyComboDesc(keyCode, keyboardModifiers)
    local comboPreview = assignWindow:recursiveGetChildById('comboPreview')
    local errorLabel = editHotkeyWindow:recursiveGetChildById('errorLabel')
    if checkHotkey(keyCombo) then
        errorLabel:setVisible(true)
        editHotkeyWindow:setHeight(180)
    else
        errorLabel:setVisible(false)
        editHotkeyWindow:setHeight(160)
    end
    comboPreview:setText(tr('Current hotkey to change: %s', keyCombo))
    comboPreview.keyCombo = keyCombo
    comboPreview:resizeToText()
    assignWindow:getChildById('applyButton'):enable()
    return true
end

function hotkeyClear(assignWindow)
    local comboPreview = assignWindow:recursiveGetChildById('comboPreview')
    comboPreview:setText(tr('Current hotkey to change: none'))
    comboPreview.keyCombo = ''
    comboPreview:resizeToText()
    assignWindow:getChildById('applyButton'):disable()
end

function hotkeyCaptureOk(assignWindow, keyCombo)
    local slot = getSlotById(slotToEdit)
    if checkHotkey(keyCombo) then
        for v, k in pairs(getAllSlots()) do
            if k.hotkey == keyCombo then
                k.hotkey = ''
                k:getChildById('key'):setText('')
            end
        end
    end
    unbindHotkeys()
    slot.hotkey = keyCombo
    local text = slot.hotkey
    text = text:gsub('Shift', 'S')
    text = text:gsub('Alt', 'A')
    text = text:gsub('Ctrl', 'C')
    text = text:gsub('+', '')
    slot:getChildById('key'):setText(text)
    setupHotkeys()
    if assignWindow == editHotkeyWindow then
        closeEditHotkeyWindow()
        return
    end
    assignWindow:destroy()
end

function saveActionBar()
    local hotkeySettings = g_settings.getNode('game_actionbar') or {}
    local hotkeys = hotkeySettings

    local char = g_game.getCharacterName()
    if not hotkeys[char] then
        hotkeys[char] = {}
    end
    hotkeys = hotkeys[char]

    table.clear(hotkeys)
    local currentHotkeys = getAllSlots()
    for v, slot in ipairs(currentHotkeys) do
        -- the scratch slot only exists to swap two slots around
        if slot:getId() ~= SWAP_SLOT_ID then
            hotkeys[slot:getId()] = {
                hotkey = slot.hotkey,
                autoSend = slot.autoSend,
                itemId = slot.itemId,
                subType = slot.subType,
                useType = slot.useType,
                text = slot.text,
                words = slot.words,
                parameter = slot.parameter
            }
        end
    end

    g_settings.setNode('game_actionbar', hotkeySettings)
    saveBarPositions()
    g_settings.save()
end

function loadSpell(slot)
    local spell, profile, spellName = Spells.getSpellByWords(slot.words)
    iconId = tonumber(Spells.getClientId(spellName))
    slot:setImageSource(Spells.getIconFileByProfile(profile))
    slot:setImageClip(Spells.getImageClip(iconId, profile))
    slot:getChildById('text'):setText('')
    slot:setBorderWidth(0)
    setupHotkeys()
end

function loadObject(slot)
    slot:setItemId(slot.itemId)
    slot:setImageSource('/images/game/actionbar/item-background')
    slot:setImageClip('0 0 0 0')
    slot:getChildById('text'):setText('')
    slot:setBorderWidth(0)
    setupHotkeys()
end

function loadText(slot)
    slot:getChildById('text'):setText(slot.text)
    while slot:getChildById('text'):getTextSize().height > 30 do
        local subString = slot:getChildById('text'):getText()
        subString = string.sub(subString, 1, #subString - 1)
        slot:getChildById('text'):setText(subString)
    end
    slot:setImageSource('/images/game/actionbar/item-background')
    slot:setImageClip('0 0 0 0')
    setupHotkeys()
end

function loadActionBar()
    unbindHotkeys()
    bulkLoading = true
    local hotkeySettings = g_settings.getNode('game_actionbar')
    local hotkeys = {}

    if not table.empty(hotkeySettings) then
        hotkeys = hotkeySettings
    end
    if not table.empty(hotkeys) then
        hotkeys = hotkeys[g_game.getCharacterName()]
    end
    if hotkeys then
        for slot, setting in pairs(hotkeys) do
            slot = getSlotById(slot)
            if slot then
                slot.itemId = setting.itemId
                slot:setItemId(setting.itemId)
                slot.subType = setting.subType
                slot.words = setting.words
                slot.text = setting.text
                slot.hotkey = setting.hotkey
                slot.useType = setting.useType
                slot.autoSend = setting.autoSend
                slot.parameter = setting.parameter
                if slot.hotkey then
                    local text = slot.hotkey
                    if type(text) == 'string' then
                        text = text:gsub('Shift', 'S')
                        text = text:gsub('Alt', 'A')
                        text = text:gsub('Ctrl', 'C')
                        text = text:gsub('+', '')
                    end
                    slot:getChildById('key'):setText(text)
                end
                if slot.words then
                    loadSpell(slot)
                elseif slot.text then
                    loadText(slot)
                elseif slot.itemId and slot.itemId > 0 then
                    loadObject(slot)
                end
            end
        end
    end

    bulkLoading = false
    setupHotkeys()
end

function round(n)
    return n % 1 >= 0.5 and math.ceil(n) or math.floor(n)
end

function updateCooldown(progressRect, duration, spellId, count)
    progressRect:setPercent(progressRect:getPercent() + 10000 / duration)
    local cd = round(duration - (progressRect:getPercent() * duration / 100)) / 1000
    if cd > 0 then
        progressRect:setText(cd .. 's')
    end

    if progressRect:getPercent() < 100 then
        removeEvent(progressRect.event)
        cooldown[spellId] = duration - count * 100
        progressRect.event = scheduleEvent(function()
            updateCooldown(progressRect, duration, spellId, count + 1)
        end, 100)
    else
        cooldown[spellId] = nil
        progressRect:destroy()
    end
end

function updateGroupCooldown(progressRect, duration, groupId)
    progressRect:setPercent(progressRect:getPercent() + 10000 / duration)
    local cd = round(duration - (progressRect:getPercent() * duration / 100)) / 1000
    if cd > 0 then
        progressRect:setText(cd .. 's')
    end

    if progressRect:getPercent() < 100 then
        removeEvent(progressRect.event)
        progressRect.event = scheduleEvent(function()
            updateGroupCooldown(progressRect, duration, groupId)
        end, 100)
    else
        groupCooldown[groupId] = nil
        progressRect:destroy()
    end
end

function onSpellCooldown(spellId, duration)
    local slot
    for v, k in pairs(getAllSlots()) do
        local spell, profile, spellName = Spells.getSpellByIcon(spellId)
        if not spell then
            print('[WARNING] Can not set cooldown on spell with id: ' .. spellId)
            return true
        end
        if k.words == spell.words or spell.clientId and spell.clientId == k.itemId then
            slot = k
            local progressRect = slot:recursiveGetChildById('progress' .. spell.id)
            if not progressRect then
                progressRect = g_ui.createWidget('SpellProgressRect', slot)
                progressRect:setId('progress' .. spell.id)
                progressRect.item = slot
                progressRect:fill('parent')
                progressRect:setFont('verdana-11px-rounded')
            else
                progressRect:setPercent(0)
            end

            local updateFunc = function()
                updateCooldown(progressRect, duration, spell.id, 0)
            end
            local finishFunc = function()
                cooldown[spell.id] = nil
                progressRect:hide()
            end
            progressRect:setPercent(0)
            updateFunc()
            cooldown[spell.id] = duration
        end
    end
end

function onSpellGroupCooldown(groupId, duration)
    local slot
    local spellGroup = 0
    for v, k in pairs(getAllSlots()) do
        local spell, profile, spellName
        if k.words then
            spell, profile, spellName = Spells.getSpellByWords(k.words)
        else
            if k.itemId and k.itemId > 0 then
                spell, profile, spellName = Spells.getSpellByClientId(k.itemId)
            end
        end
        if spell then
            if table.contains(spell.group, groupId) then
                local continue = false
                if not cooldown[spell.id] or cooldown[spell.id] and cooldown[spell.id] < duration then
                    local oldProgressBar = k:recursiveGetChildById('progress' .. spell.id)
                    if oldProgressBar then
                        cooldown[spell.id] = nil
                        oldProgressBar:hide()
                    end
                    continue = true
                elseif cooldown[spell.id] and cooldown[spell.id] >= duration then
                    continue = false
                end
                if continue then
                    slot = k
                    local progressRect = slot:recursiveGetChildById('progress' .. groupId)
                    if not progressRect then
                        progressRect = g_ui.createWidget('SpellProgressRect', slot)
                        progressRect:setId('progress' .. groupId)
                        progressRect.item = slot
                        progressRect:fill('parent')
                        progressRect:setFont('verdana-11px-rounded')
                    else
                        progressRect:setPercent(0)
                    end

                    local updateFunc = function()
                        updateGroupCooldown(progressRect, duration, groupId)
                    end
                    local finishFunc = function()
                        groupCooldown[groupId] = false
                        progressRect:hide()
                    end
                    progressRect:setPercent(0)
                    updateFunc()
                    groupCooldown[groupId] = true
                end
            end
        end
    end
end

function filterSpells(text)
    if #text > 0 then
        text = text:lower()

        for index, spellListLabel in pairs(spellsPanel:getChildren()) do
            if string.find(spellListLabel.name:lower(), text) or string.find(spellListLabel.words:lower(), text) then
                showSpell(spellListLabel)
            else
                hideSpell(spellListLabel)
            end
        end

    else
        for index, spellListLabel in pairs(spellsPanel:getChildren()) do
            showSpell(spellListLabel)
        end
    end
end

function hideSpell(spellListLabel)
    if spellListLabel:isVisible() then
        spellListLabel:hide()
        spellListLabel:setHeight(0)
    end
end

function showSpell(spellListLabel)
    if not spellListLabel:isVisible() then
        spellListLabel:setHeight(spellListLabel.defaultHeight)
        spellListLabel:show()
    end
end
