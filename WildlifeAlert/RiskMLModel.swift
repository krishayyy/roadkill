import CoreML
import Foundation

/// Thin wrapper around the compiled WildlifeRiskModel CoreML model
/// (WildlifeRiskModel.mlpackage), which Xcode auto-generates a
/// `WildlifeRiskModel` Swift class for at build time.
///
/// This model is a GradientBoostingClassifier trained on REAL animal-vehicle
/// collision records combined from five states' official open crash data —
/// Iowa DOT "Crash Data (SOR)", Illinois DOT "Crashes - 2023" (single year
/// only), VDOT "CrashData Basic", MassDOT "IMPACT Crashes" (2019-2025), and
/// TDOT "Tennessee Crashes" (Jan 2021-Jan 2025) — 955,848 total sampled rows,
/// 318,616 coded as animal-vehicle collisions. Honest metrics come from a
/// leakage-audited spatial cross-validation (train/test split on spatial
/// blocks, not random rows, so the model is never tested on locations it
/// effectively saw during training): ROC AUC 0.8205, accuracy 0.7646,
/// average precision 0.6802 (crossfit_spatial_cv over all 5 states; see
/// scratchpad_data/training_evaluations_v3.json for the full breakdown,
/// including a naive random-split number that reads better — 0.8409 ROC
/// AUC — but leaks spatial autocorrelation and overstates real performance).
/// Per-state spatial-CV ROC AUC ranges from 0.767 (MA) to 0.848 (IA).
///
/// Feature importance from the final model is worth stating honestly rather
/// than assumed: hour_of_day (0.556), corridor_base_severity (0.184), and
/// month (0.140) drive nearly the entire prediction. species_Deer/Elk/Moose
/// each have ~0.0 importance — essentially no predictive value — because
/// none of the five source datasets carry a real species field (all
/// positives are inferred from crash-cause text, not species-coded), so the
/// model never learned a species signal to exploit. The species inputs are
/// left in place below for interface stability and future data sources that
/// might carry real species labels, not because they currently matter.
///
/// Known limitations, stated honestly rather than glossed over: this covers
/// IA/IL/VA/MA/TN only, not nationwide. Outside those five states there is
/// no corridor for the model to score against, so RiskEngine doesn't call it
/// at all — it falls back to the rule-based engine alone and reports the
/// result as an explicitly-labelled ambient estimate (see RiskScore.Basis). Several other state portals
/// were checked and found not bulk-downloadable without a login or
/// open-records request; several more simply haven't been checked yet.
/// road_type is inferred per-state from different heuristics, not a unified
/// classification. The model runs entirely on-device; no network/LLM call
/// happens at inference time.
///
/// One learned relationship is real but not usable as a risk signal: the
/// model predicts markedly *lower* collision probability for fog/rain/snow
/// than for clear weather. That reflects exposure, not danger — almost all
/// driving happens in clear conditions, so clear weather accumulates the most
/// crash records and frequency swamps per-mile risk in the training signal.
/// RiskEngine therefore calls `predictProbability` with a fixed `.clear`
/// weather reference and applies its own visibility-based weather multiplier
/// to the blended result. The `weatherCondition` parameter is kept because
/// the model genuinely accepts those inputs, and a future model trained with
/// per-mile exposure normalization could use them correctly.
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
