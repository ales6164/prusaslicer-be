import GCodeReader from "./libs/gcode-analyzer/gcode-analyzer/GCodeReader";
import {analyzeModel} from "./libs/gcode-analyzer/gcode-analyzer/tmpnameuntilrefactor";
import {readFile} from "node:fs/promises";
import {prettyCurrencyObject} from "./utils.ts";
import Currency from "currency.js";

export async function getPriceAndTimeEstimate(gCodePath: string) {
    const gCodeContent = await readFile(gCodePath, "utf8"),
        model = new GCodeReader().loadFile(gCodeContent),
        analysis = analyzeModel(model as any),
        quickAnalysis = analysis ? {
            // Map analysis results, ensuring null safety
            max: analysis.max ?? null,
            min: analysis.min ?? null,
            modelSize: analysis.modelSize ?? null,
            totalFilament: analysis.totalFilament ?? null,
            filamentByExtruder: analysis.filamentByExtruder ?? null,
            printTime: analysis.printTime ?? null,
            layerHeight: analysis.layerHeight ?? null,
            layerCnt: analysis.layerCnt ?? null // Property names as per your GCodeReader output
            // layerTotal: analysis.layerTotal ?? null // Example if you have this
        } : null

    // Price calculation - make base price and multiplier configurable
    const BASE_PRICE = 1.00 // e.g., 1 unit of currency
    const PRICE_PER_FILAMENT_UNIT = 0.01 // e.g., 0.01 per mm (check unit!)
    const filamentAmount = Number(quickAnalysis?.totalFilament ?? 0)
    const variablePrice = filamentAmount * PRICE_PER_FILAMENT_UNIT
    const finalPrice = quickAnalysis ? BASE_PRICE + variablePrice : 0

    // Time calculation - make base time and multiplier configurable
    const BASE_TIME = 1.00
    const TIME_PER_LAYER = 0.01
    const layerAmount = Number(quickAnalysis?.layerCnt ?? 0)
    const variableTime = layerAmount * TIME_PER_LAYER
    const finalTime = quickAnalysis ? BASE_TIME + variableTime : 0

    return {
        priceEstimate: prettyCurrencyObject(Currency(finalPrice)),
        timeEstimate: finalTime,
        quickAnalysis,
    }
}