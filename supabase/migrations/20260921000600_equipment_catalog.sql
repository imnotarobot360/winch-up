-- Winch Up :: extend the equipment catalogue
--
-- Phase 4 lists nine items. Five of them are not in equipment_type yet. The existing eight stay:
-- four of them (tractor, second_truck, lifted_4x4, night_lights) are capabilities the dispatch
-- engine matches on and the spec's list simply does not mention, and dropping them would make
-- matching worse rather than more compliant.
--
--   spec "Winch"                  -> winch                   (existing)
--   spec "Recovery straps"        -> kinetic_rope            (existing)
--   spec "Traction boards"        -> traction_boards         (existing)
--   spec "Soft shackles"          -> soft_shackles           (new)
--   spec "Rated recovery points"  -> rated_recovery_points   (new)
--   spec "Air compressor"         -> air_compressor          (new)
--   spec "Tire repair equipment"  -> tire_repair             (new)
--   spec "Jack and lifting"       -> jack_lifting            (new)
--   spec "Other recovery tools"   -> covered by vehicles.notes rather than an enum value that
--                                    means nothing to a matching query
--
-- Kept as an enum rather than moved to a catalogue table, deliberately: responders.equipment is
-- equipment_type[] and app.candidates() matches with `r.equipment @> req.required_equipment`.
-- That containment operator on an enum array is what makes ring queries cheap. A lookup table
-- would turn every match into a join for the sake of letting an admin invent equipment types
-- that no request can ask for.
--
-- `alter type ... add value` cannot be used in the transaction that adds it, so nothing here
-- references the new values. The vehicles table is the next migration.

alter type equipment_type add value if not exists 'soft_shackles';
alter type equipment_type add value if not exists 'rated_recovery_points';
alter type equipment_type add value if not exists 'air_compressor';
alter type equipment_type add value if not exists 'tire_repair';
alter type equipment_type add value if not exists 'jack_lifting';
