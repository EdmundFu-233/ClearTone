using System.Text.Json;
using System.Text.Json.Serialization;
using ClearTone.Core.Models;

namespace ClearTone.Core.Persistence;

public static class JsonDefaults
{
    public static readonly JsonSerializerOptions Options = Create();

    private static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals,
            DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        };
        options.Converters.Add(new SongSourceJsonConverter());
        options.Converters.Add(new AppSettingsJsonConverter());
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }
}

public sealed class SongSourceJsonConverter : JsonConverter<SongSource>
{
    public override SongSource Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.String)
        {
            var raw = reader.GetString();
            return raw == "local" ? SongSource.Local : SongSource.Netease;
        }
        if (reader.TokenType == JsonTokenType.Number)
        {
            return reader.GetInt32() == 1 ? SongSource.Local : SongSource.Netease;
        }
        return SongSource.Netease;
    }

    public override void Write(Utf8JsonWriter writer, SongSource value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value == SongSource.Local ? "local" : "netease");
    }
}
