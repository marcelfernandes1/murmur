using System.ComponentModel;
using System.Diagnostics;
using System.Windows.Controls;
using Murmur.Windows.Services;

namespace Murmur.Windows.Views;

public partial class MainWindow : Window
{
    private readonly DictationController controller;
    private bool canClose;
    private Guid? latestHistory;
    private int historyCount = -1;
    internal MainWindow(DictationController controller)
    {
        InitializeComponent();
        this.controller = controller;
        ModelBox.ItemsSource = ModelCatalog.Speech;
        LanguageBox.ItemsSource = Settings.Languages.Select(l => new Choice(l.Code, l.Name)).ToArray();
        TriggerBox.ItemsSource = Settings.TriggerKeys.Select(k => new Choice(k.Key.ToString(), k.Value)).ToArray();
        var s = controller.Settings;
        ModelBox.SelectedItem = ModelCatalog.Find(s.ModelId);
        LanguageBox.SelectedIndex = Array.FindIndex(Settings.Languages, l => l.Code == s.Language);
        TriggerBox.SelectedItem = TriggerBox.Items.Cast<Choice>().First(c => c.Value == s.TriggerKey.ToString());
        LoadMicrophones();
        HandsFreeBox.IsChecked = s.HandsFree; FillersBox.IsChecked = s.RemoveFillers;
        CleanupBox.IsChecked = s.SmartCleanup; HistoryBox.IsChecked = s.SaveHistory;
        SoundBox.IsChecked = s.SoundEffects; StartupBox.IsChecked = s.LaunchAtLogin;
        VocabularyBox.Text = string.Join(Environment.NewLine, s.Vocabulary);
        controller.Changed += Refresh;
        Closing += OnClosing;
        Refresh();
    }
    private void Refresh()
    {
        StatusText.Text = controller.Status;
        ShortcutHelp.Text = $"Hold {Settings.TriggerKeys[controller.Settings.TriggerKey]} in any app, speak, then release to paste. Press Esc to cancel. Nothing you say leaves this PC.";
        SettingsPanel.IsEnabled = !controller.Busy;
        PrepareButton.Visibility = controller.Busy ? Visibility.Collapsed : Visibility.Visible;
        CancelButton.Visibility = controller.Busy ? Visibility.Visible : Visibility.Collapsed;
        RetryButton.Visibility = controller.CanRetry ? Visibility.Visible : Visibility.Collapsed;
        DownloadBar.Visibility = controller.IsPreparing ? Visibility.Visible : Visibility.Collapsed;
        DownloadBar.Value = controller.DownloadProgress;
        DownloadBar.IsIndeterminate = controller.IsPreparing && controller.DownloadProgress == 0;
        if (controller.History.FirstOrDefault()?.Id != latestHistory || controller.History.Count != historyCount) RefreshHistory();
    }
    private void LoadMicrophones()
    {
        try
        {
            var selected = (MicrophoneBox.SelectedItem as Microphone)?.Id ?? controller.Settings.MicrophoneId;
            var microphones = AudioRecorder.Devices();
            // Retain an unavailable explicit device rather than silently changing it.
            if (selected is not null && microphones.All(m => m.Id != selected)) microphones.Add(new(selected, "Saved microphone (unavailable)"));
            MicrophoneBox.ItemsSource = microphones;
            MicrophoneBox.SelectedItem = microphones.First(m => m.Id == selected);
        }
        catch (Exception) { StatusText.Text = "No microphone is available. Connect one and select Refresh microphones."; }
    }
    private void Save_Click(object sender, RoutedEventArgs e) => Save(ReadSettings);
    private Settings ReadSettings() => controller.Settings with
    {
        ModelId = ((ModelInfo)ModelBox.SelectedItem).Id,
        Language = ((Choice)LanguageBox.SelectedItem).Value,
        TriggerKey = int.Parse(((Choice)TriggerBox.SelectedItem).Value),
        MicrophoneId = (MicrophoneBox.SelectedItem as Microphone)?.Id,
        HandsFree = HandsFreeBox.IsChecked == true, RemoveFillers = FillersBox.IsChecked == true,
        SmartCleanup = CleanupBox.IsChecked == true, SaveHistory = HistoryBox.IsChecked == true,
        SoundEffects = SoundBox.IsChecked == true, LaunchAtLogin = StartupBox.IsChecked == true
    };
    private void SaveVocabulary_Click(object sender, RoutedEventArgs e)
    {
        var entries = VocabularyBox.Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(s => s.Trim()).Where(s => s.Length > 0).ToArray();
        if (entries.Length > 100 || entries.Any(s => s.Length > 80)) { StatusText.Text = "Use up to 100 vocabulary entries, each no longer than 80 characters."; return; }
        Save(() => controller.Settings with { Vocabulary = entries });
    }
    private void Save(Func<Settings> value, bool prepare = false)
    {
        try { controller.SaveSettings(value()); if (prepare) controller.PrepareModels(); }
        catch (Exception) { StatusText.Text = controller.Busy ? "Finish your current dictation or download, then save." : "Settings could not be saved. Check free disk space and folder access, then try again."; }
    }
    private void Prepare_Click(object sender, RoutedEventArgs e) => Save(ReadSettings, prepare: true);
    private void Cancel_Click(object sender, RoutedEventArgs e) => controller.Cancel();
    private void Retry_Click(object sender, RoutedEventArgs e) => controller.Retry();
    private void RefreshMics_Click(object sender, RoutedEventArgs e) => LoadMicrophones();
    private void Search_Changed(object sender, TextChangedEventArgs e) { if (controller is not null) RefreshHistory(); }
    private void RefreshHistory()
    {
        var query = SearchBox.Text.Trim();
        var items = controller.History.Where(t => t.Text.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        HistoryList.ItemsSource = items;
        EmptyHistory.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        EmptyHistory.Text = query.Length > 0 ? "No dictations match your search." : "Your words will appear here after your first dictation.";
        latestHistory = controller.History.FirstOrDefault()?.Id; historyCount = controller.History.Count;
    }
    private async void Copy_Click(object sender, RoutedEventArgs e)
    {
        try { await TextDelivery.CopyAsync((string)((Button)sender).Tag, CancellationToken.None); StatusText.Text = "Copied to your clipboard."; }
        catch (Exception) { StatusText.Text = "The clipboard is busy. Try Copy again in a moment."; }
    }
    private void ClearHistory_Click(object sender, RoutedEventArgs e)
    {
        if (controller.History.Count == 0) return;
        if (MessageBox.Show(this, "Permanently delete the dictations saved on this PC?", "Clear history", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
        try { controller.ClearHistory(); }
        catch (Exception) { StatusText.Text = "History could not be cleared. Check folder access and try again."; }
    }
    private void Privacy_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
        catch (Exception) { StatusText.Text = "Open Windows Settings → Privacy & security → Microphone and allow desktop apps."; }
    }
    private void OnClosing(object? sender, CancelEventArgs e) { if (!canClose) { e.Cancel = true; Hide(); } }
    internal void AllowClose() { canClose = true; Close(); }
    private sealed record Choice(string Value, string Label) { public override string ToString() => Label; }
}
