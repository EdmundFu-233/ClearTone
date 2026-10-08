using System.Globalization;
using System.Text.Json;

namespace ClearTone.Core.Models;

public static class JsonHelpers
{
    public static JsonElement? Prop(this JsonElement element, string name) => ((JsonElement?)element).Prop(name);

    public static string? AsString(this JsonElement element) => ((JsonElement?)element).AsString();

    public static double? AsDouble(this JsonElement element) => ((JsonElement?)element).AsDouble();

    public static int? AsInt(this JsonElement element) => ((JsonElement?)element).AsInt();

    public static long? AsLong(this JsonElement element) => ((JsonElement?)element).AsLong();

    public static bool? AsBool(this JsonElement element) => ((JsonElement?)element).AsBool();

    public static List<JsonElement>? AsArray(this JsonElement element) => ((JsonElement?)element).AsArray();

    public static string? AsIDString(this JsonElement element) => ((JsonElement?)element).AsIDString();

    public static bool HasValue(this JsonElement element) => true;

    public static JsonElement? Prop(this JsonElement? element, string name)
    {
        if (element is not { ValueKind: JsonValueKind.Object } obj) return null;
        if (!obj.TryGetProperty(name, out var value)) return null;
        return value.ValueKind == JsonValueKind.Null ? null : value;
    }

    public static string? AsString(this JsonElement? element) =>
        element is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;

    public static double? AsDouble(this JsonElement? element)
    {
        if (element is not { } value) return null;
        switch (value.ValueKind)
        {
            case JsonValueKind.Number:
                if (value.TryGetInt64(out var integer)) return integer;
                return value.TryGetDouble(out var number) ? number : null;
            case JsonValueKind.String:
                return double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed)
                    ? parsed
                    : null;
            default:
                return null;
        }
    }

    public static int? AsInt(this JsonElement? element)
    {
        var number = element.AsDouble();
        if (number is null) return null;
        if (number.Value > int.MaxValue || number.Value < int.MinValue) return null;
        return (int)Math.Round(number.Value);
    }

    public static long? AsLong(this JsonElement? element)
    {
        if (element is not { } value) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var integer)) return integer;
        var number = element.AsDouble();
        return number is null ? null : (long)number.Value;
    }

    public static bool? AsBool(this JsonElement? element)
    {
        if (element is not { } value) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.Number => value.TryGetDouble(out var number) && number != 0,
            JsonValueKind.String => value.GetString() switch
            {
                "true" or "1" => true,
                "false" or "0" => false,
                _ => null,
            },
            _ => null,
        };
    }

    public static List<JsonElement>? AsArray(this JsonElement? element)
    {
        if (element is not { ValueKind: JsonValueKind.Array } array) return null;
        return array.EnumerateArray().ToList();
    }

    public static string? AsIDString(this JsonElement? element)
    {
        if (element is not { } value) return null;
        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText().Trim(),
            _ => null,
        };
    }

    public static bool HasValue(this JsonElement? element) => element is not null;

    public static List<T> CompactMap<T>(this IEnumerable<JsonElement>? elements, Func<JsonElement, T?> map)
        where T : class
    {
        var result = new List<T>();
        if (elements is null) return result;
        foreach (var element in elements)
        {
            var value = map(element);
            if (value is not null) result.Add(value);
        }
        return result;
    }
}
