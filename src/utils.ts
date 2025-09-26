import Currency from "currency.js"

/**
 * Returns lowercase file extension (including dot) or empty string.
 */
export function extOf(name: string) {
    const i = name.lastIndexOf(".");
    return i >= 0 ? name.slice(i).toLowerCase() : "";
}

/**
 * Generates a short unique basename for temp files.
 */
export function randomBase(prefix: string) {
    return `${prefix}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}


export function _formatCurrency(currencyObject: Currency, _currency = "EUR") {
    if (!currencyObject?.format) return ""
    return currencyObject.format({
        decimal: ",",
        separator: ".",
        fromCents: false,
        precision: 2,
        symbol: ""
    }) + " " + _currency
}

export function prettyCurrencyObject(currencyObject: Currency, _currency = "EUR") {
    return {
        intValue: currencyObject.intValue,
        value: currencyObject.value,
        formatted: _formatCurrency(currencyObject, _currency),
        currency: _currency
    }
}