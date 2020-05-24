#define MAX_AREA_SIZE 300

/mob/observer/eye/blueprints
	
	var/list/selected_turfs = list() // Associative list of turfs -> boolean validity that the player has selected for new area creation.
	var/list/selection_images = list()
	var/turf/last_selected_turf
	var/image/last_selected_image
	
	// On what Z-levels this can be used to modify or create areas.
	var/list/valid_z_levels = list()

	// Displayed to the user to allow them to see what area they're hovering over.
	var/obj/effect/overlay/area_name_effect
	var/area_prefix
	
	// Displayed to the user on failed area creation.
	var/list/errors = list()

/mob/observer/eye/blueprints/Initialize(var/mapload, var/list/valid_zls, var/area_p)
	. = ..(mapload)

	valid_z_levels = valid_zls
	area_prefix = area_p

	area_name_effect = new()

	area_name_effect.maptext_height = 64
	area_name_effect.maptext_width = 128
	area_name_effect.layer = FLOAT_LAYER
	area_name_effect.plane = HUD_PLANE
	area_name_effect.appearance_flags = APPEARANCE_UI_IGNORE_ALPHA
	area_name_effect.screen_loc = "LEFT+1,BOTTOM+2"

	last_selected_image = image('icons/effects/blueprints.dmi', "selected")
	last_selected_image.plane = OBSERVER_PLANE
	last_selected_image.appearance_flags = NO_CLIENT_COLOR

/mob/observer/eye/blueprints/Destroy()
	. = ..()
	QDEL_NULL(area_name_effect)
	errors = null
	selected_turfs = null
	valid_z_levels = null
	last_selected_turf = null

/mob/observer/eye/blueprints/release(var/mob/user)
	if(owner && owner.client && user == owner)
		owner.client.images.Cut()
	. = ..()
	
/mob/observer/eye/blueprints/proc/create_area()
	var/area_name = sanitizeSafe(input("New area name:","Blueprint Editing", ""), MAX_NAME_LEN)
	if(!area_name || !length(area_name))
		return
	if(length(area_name) > 50)
		to_chat(owner, SPAN_WARNING("That name is too long!"))
		return

	if(!check_selection_validity())
		to_chat(owner, SPAN_WARNING("Could not mark area: [english_list(errors)]!"))
		return

	var/area/A = new
	A.SetName(area_name)
	A.power_equip = 0
	A.power_light = 0
	A.power_environ = 0
	A.always_unpowered = 0
	for(var/turf/T in selected_turfs)
		ChangeArea(T, A)
	remove_selection() // Reset the selection for clarity.

/mob/observer/eye/blueprints/proc/remove_area()
	var/area/A = get_area(src)
	if(!check_modification_validity())
		return
	if(A.apc)
		to_chat(owner, SPAN_WARNING("You must remove the APC from this area before you can remove it from the blueprints!"))
		return
	to_chat(owner, SPAN_NOTICE("You scrub [A.name] off the blueprints."))
	log_and_message_admins("deleted area [A.name] via station blueprints.")
	qdel(A)

/mob/observer/eye/blueprints/proc/edit_area()
	var/area/A = get_area(src)
	if(!check_modification_validity())
		return
	var/prevname = A.name
	var/new_area_name = sanitizeSafe(input("New area name:","Blueprint Editing", prevname), MAX_NAME_LEN)
	if(!new_area_name || !LAZYLEN(new_area_name) || new_area_name==prevname)
		return
	if(length(new_area_name) > 50)
		to_chat(owner, SPAN_WARNING("Text too long."))
		return
	
	// Adjusting titles in the old area.
	for(var/obj/machinery/alarm/M in A)
		M.SetName(replacetext(M.name,prevname,new_area_name))
	for(var/obj/machinery/power/apc/M in A)
		M.SetName(replacetext(M.name,prevname,new_area_name))
	for(var/obj/machinery/atmospherics/unary/vent_scrubber/M in A)
		M.SetName(replacetext(M.name,prevname,new_area_name))
	for(var/obj/machinery/atmospherics/unary/vent_pump/M in A)
		M.SetName(replacetext(M.name,prevname,new_area_name))
	for(var/obj/machinery/door/M in A)
		M.SetName(replacetext(M.name,prevname,new_area_name))

	A.SetName(new_area_name)
	to_chat(owner, SPAN_NOTICE("You set the area '[prevname]' title to '[new_area_name]'."))

/mob/observer/eye/blueprints/ClickOn(var/atom/A, var/list/params)
	params = params2list(params)

	if(!canClick())
		return
	if(params["left"])
		update_selected_turfs(get_turf(A), params)

/mob/observer/eye/blueprints/proc/update_selected_turfs(var/turf/next_selected_turf, var/list/params)
	if(!next_selected_turf)
		return

	if(!last_selected_turf) // The player has only placed down one corner of the block.
		last_selected_turf = next_selected_turf
		last_selected_image.loc = last_selected_turf
		return

	if(last_selected_turf.z != next_selected_turf.z) // No multi-Z areas. Contiguity checks this as well, but this is cheaper.
		return
	
	var/list/new_selection = block(last_selected_turf, next_selected_turf)

	if(params["shift"])		   // Shift click to remove areas from the selection.
		selected_turfs -= new_selection
	else
		selected_turfs |= new_selection

	last_selected_image.loc = null // Remove the last selected turf indicator image.

	check_selection_validity()
	update_images()
	last_selected_turf = null

// Completes all the necessary checks for creating new areas, starting at the turf level before checking contiguity. 
/mob/observer/eye/blueprints/proc/check_selection_validity()
	. = TRUE
	errors.Cut()

	if(!LAZYLEN(selected_turfs)) // Sanity check
		errors |= "no turfs are selected"
		return FALSE

	if(selected_turfs.len > MAX_AREA_SIZE)
		errors |= "selection exceeds max size"
		return FALSE

	for(var/turf/T in selected_turfs)
		var/turf_valid = check_turf_validity(T)
		. = min(., turf_valid)
		selected_turfs[T] = turf_valid
	
	if(!.) return // Skip checking contiguity if there's other errors with individual turfs.
	. = check_contiguity()

/mob/observer/eye/blueprints/proc/check_turf_validity(var/turf/T)
	. = TRUE
	if(!T)
		return FALSE
	if(!(T.z in valid_z_levels))
		errors |= "selection isn't marked on the blueprints"
		. = FALSE
	var/area/A = T.loc
	if(!A) // Safety check
		errors |= "selection overlaps unknown location"
		return FALSE
	if(!(A.area_flags & AREA_FLAG_IS_BACKGROUND)) // Cannot create new areas over old ones.
		errors |= "selection overlaps other area"
		. = FALSE
	if(istype(T, (A.base_turf ? A.base_turf : /turf/space)))
		errors |= "selection is exposed to the outside"
		. = FALSE

/mob/observer/eye/blueprints/proc/check_contiguity()
	var/turf/start_turf = pick(selected_turfs)
	var/list/pending_turfs = list(start_turf)
	var/list/checked_turfs = list()
	
	while(pending_turfs.len)
		if(LAZYLEN(checked_turfs) > MAX_AREA_SIZE)
			errors |= "selection exceeds max size"
			break
		var/turf/T = pending_turfs[1]
		pending_turfs -= T
		for(var/dir in GLOB.cardinal)	// Floodfill to find all turfs contiguous with the randomly chosen start_turf.
			var/turf/NT = get_step(T, dir)
			if(!isturf(NT) || !(NT in selected_turfs) || (NT in pending_turfs) || (NT in checked_turfs))
				continue
			pending_turfs += NT	

		checked_turfs += T
	
	var/list/incontiguous_turfs = (selected_turfs.Copy() - checked_turfs) 

	if(LAZYLEN(incontiguous_turfs)) // If turfs still remain in incontiguous_turfs, there are non-contiguous turfs in the selection.
		errors |= "selection must be contiguous"
		return FALSE
	
	return TRUE

// For checks independent of the selection.
/mob/observer/eye/blueprints/proc/check_modification_validity()
	. = TRUE
	var/area/A = get_area(src)
	if(!(A.z in valid_z_levels))
		to_chat(owner, SPAN_WARNING("The markings on this are entirely irrelevant to your whereabouts!"))
		return FALSE
	if(A in SSshuttle.shuttle_areas)
		to_chat(owner, SPAN_WARNING("This segment of the blueprints looks far too complex. Best not touch it!"))
		return FALSE
	if(!A || (A.area_flags & AREA_FLAG_IS_BACKGROUND))
		to_chat(owner, SPAN_WARNING("This area is not marked on the blueprints!"))
		return FALSE

/mob/observer/eye/blueprints/proc/remove_selection()
	selected_turfs.Cut()
	update_images()

/mob/observer/eye/blueprints/proc/update_images()
	if(!owner || !owner.client)
		return
	
	owner.client.images -= selection_images
	selection_images.Cut()
	
	if(LAZYLEN(selected_turfs))
		for(var/turf/T in selected_turfs)
			var/selection_icon_state = selected_turfs[T] ? "valid" : "invalid"
			var/image/I = image('icons/effects/blueprints.dmi', T, selection_icon_state)
			I.plane = OBSERVER_PLANE
			I.appearance_flags = NO_CLIENT_COLOR
			selection_images += I
	
	owner.client.images |= last_selected_image
	owner.client.images += selection_images

/mob/observer/eye/blueprints/setLoc(var/turf/T)
	. = ..()
	if(.)
		var/style = "font-family: 'Fixedsys'; -dm-text-outline: 1 black; font-size: 11px;"
		var/area/A = get_area(src)
		if(!A)
			return
		area_name_effect.maptext = "<span style=\"[style]\">[area_prefix], [A.name]</span>"

/mob/observer/eye/blueprints/apply_visual(var/mob/M)
	. = ..()
	if(!.) return

	M.overlay_fullscreen("blueprints", /obj/screen/fullscreen/blueprints)
	M.client.screen += area_name_effect
	M.add_client_color(/datum/client_color/monochrome)

/mob/observer/eye/blueprints/remove_visual(var/mob/M)
	. = ..()
	if(!.) return

	M.clear_fullscreen("blueprints", 0)
	M.client.screen -= area_name_effect
	M.remove_client_color(/datum/client_color/monochrome)

/mob/observer/eye/blueprints/additional_sight_flags()
	return SEE_TURFS|BLIND

#undef MAX_AREA_SIZE