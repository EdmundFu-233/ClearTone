namespace ClearTone.Core.Models;

public record RadioStation
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string? CoverURL { get; set; }
    public int ProgramCount { get; set; }
    public int SubscriberCount { get; set; }
    public string? CreatorName { get; set; }
    public string? CategoryName { get; set; }
    public string? DescriptionText { get; set; }
    public bool IsSubscribed { get; set; }
}

public record RadioProgram
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public string? CoverURL { get; set; }
    public double Duration { get; set; }
    public DateTimeOffset? CreateTime { get; set; }
    public int PlayCount { get; set; }
    public string? StationName { get; set; }
    public Song? Song { get; set; }

    public bool IsPlayable => Song?.IsPlayable ?? false;
}

public record RadioCategory
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public List<string> SubCategories { get; set; } = new();
}
