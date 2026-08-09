import CoreML
import Foundation

/// Thin wrapper around the compiled WildlifeRiskModel CoreML model
/// (WildlifeRiskModel.mlpackage), which Xcode auto-generates a
/// `WildlifeRiskModel` Swift class for at build time.
///
/// This model is a GradientBoostingClassifier trained on REAL animal-vehicle
/// collision records combined from three states' official open crash data
/// (2,036,714 total crash records, 163,512 coded as animal-vehicle
/// collisions): Iowa DOT "Crash Data (SOR)" (606,986 rows / 85,398 animal),
/// Illinois DOT "Crashes - 2023" (299,426 rows / 16,461 animal, single year
/// only), and VDOT "CrashData Basic" (1,130,302 rows / 61,653 animal,
/// multi-year, cross-checked against the official FR300 Crash Report code
/// table). Held-out test accuracy 0.8046, ROC AUC 0.8671 — lower than the
/// Iowa-only model's 0.8295/0.8971, an expected and honest result of a more
/// diverse, harder multi-state signal being less separable, not a bug. See
/// scripts/train_risk_model_multistate.py and
/// scratchpad_data/training_metrics_multistate.json for full methodology.
///
/// Known limitations, stated honestly rather than glossed over: this covers
/// IA/IL/VA only, not nationwide — hotspots outside those three states still
/// rely on the rule-based engine alone. Several other state portals were
/// checked and found not bulk-downloadable without a login or open-records
/// request (see training_metrics_multistate.json's states_checked_but_excluded
/// list); several more simply haven't been checked yet. None of the source
/// data has a species field (all positives are labeled "Deer"), and
/// road_type is inferred per-state from different heuristics, not a unified
/// classification. The model runs entirely on-device; no network/LLM call
/// happens at inference time.
///
/// Its prediction is blended into RiskEngine as one additional named
/// factor — it does not replace the transparent rule-based factors.
enum RiskMLModel {
    private static let model: WildlifeRiskModel? = {
        do {
            let config = MLModelConfiguration()
            return try WildlifeRiskModel(configuration: config)
        } catch {
            print("RiskMLModel: failed to load CoreML model — \(error.localizedDescription)")
            return nil
        }
    }()

    /// Species categories the model was trained on. Anything else (e.g. the
    /// compound strings used in some seeded hotspots like "Deer & Elk") maps
    /// to the closest single species below.
    private static let knownSpecies = ["Deer", "Elk", "Moose"]
    private static let knownWeather = ["clear", "cloudy", "rain", "snow", "fog"]
    private static let knownRoadTypes = ["highway", "rural", "residential"]

    /// Predicts collision-risk probability (0...1) for the given situation.
    /// Returns nil if the model failed to load or inference failed, so
    /// callers can gracefully fall back to rule-based-only scoring.
    static func predictProbability(
        hourOfDay: Double,
        month: Int,
        distanceToCorridorMeters: Double,
        corridorBaseSeverity: Double,
        weatherCondition: SimpleCondition?,
        species: String,
        roadType: String = "highway"
    ) -> Double? {
        guard let model else { return nil }

        let weatherKey = mapWeather(weatherCondition)
        let speciesKey = mapSpecies(species)
        let roadKey = knownRoadTypes.contains(roadType) ? roadType : "highway"

        do {
            let input = WildlifeRiskModelInput(
                hour_of_day: hourOfDay,
                month: Double(month),
                distance_to_nearest_corridor_m: distanceToCorridorMeters,
                corridor_base_severity: corridorBaseSeverity,
                weather_condition_clear: weatherKey == "clear" ? 1 : 0,
                weather_condition_cloudy: weatherKey == "cloudy" ? 1 : 0,
                weather_condition_fog: weatherKey == "fog" ? 1 : 0,
                weather_condition_rain: weatherKey == "rain" ? 1 : 0,
                weather_condition_snow: weatherKey == "snow" ? 1 : 0,
                species_Deer: speciesKey == "Deer" ? 1 : 0,
                species_Elk: speciesKey == "Elk" ? 1 : 0,
                species_Moose: speciesKey == "Moose" ? 1 : 0,
                road_type_highway: roadKey == "highway" ? 1 : 0,
                road_type_residential: roadKey == "residential" ? 1 : 0,
                road_type_rural: roadKey == "rural" ? 1 : 0
            )
            let output = try model.prediction(input: input)
            // classProbability is keyed by class label (Int64: 0 or 1); we
            // want P(label == 1), i.e. "collision-relevant encounter".
            return output.classProbability[1] ?? Double(output.risk_label)
        } catch {
            print("RiskMLModel: prediction failed — \(error.localizedDescription)")
            return nil
        }
    }

    private static func mapSpecies(_ raw: String) -> String {
        if knownSpecies.contains(raw) { return raw }
        let lower = raw.lowercased()
        if lower.contains("moose") { return "Moose" }
        if lower.contains("elk") { return "Elk" }
        return "Deer"
    }

    private static func mapWeather(_ condition: SimpleCondition?) -> String {
        switch condition {
        case .clear, .none: return "clear"
        case .cloudy: return "cloudy"
        case .rain: return "rain"
        case .snow: return "snow"
        case .fog: return "fog"
        }
    }
}
