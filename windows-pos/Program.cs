using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace IprintDesk;
internal static class Program {
 internal const string Site="https://iprintast-maker.github.io/cloudshop/";
 internal const string Title="Айпринт · касса";
 [STAThread] static void Main(string[] args){
  if(args.Contains("--self-test")){ApplicationConfiguration.Initialize();using var test=new DeskForm();test.CreateControl();File.WriteAllText(Path.Combine(Path.GetTempPath(),"iprint-desk-self-test.txt"),"PASS: WinForms, WebView2 control, settings and toolbar initialized");return;}
  using var mutex=new Mutex(true,"Local\\IprintDeskSingleInstance",out var created);
  if(!created){var h=FindWindow(null,Title);if(h!=IntPtr.Zero){PostMessage(h,0x8002,IntPtr.Zero,IntPtr.Zero);SetForegroundWindow(h);}return;}
  ApplicationConfiguration.Initialize();Application.Run(new DeskForm());
 }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] static extern IntPtr FindWindow(string? c,string? n);
 [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h,int m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
}
internal sealed record DeskSettings(int X=80,int Y=80,int Width=590,int Height=850,bool Pinned=true);
internal sealed class DeskForm:Form {
 readonly WebView2 web=new(){Dock=DockStyle.Fill};
 readonly ToolStrip strip=new(){GripStyle=ToolStripGripStyle.Hidden,Padding=new Padding(5),AutoSize=false,Height=38};
 readonly ToolStripButton pin=new("Поверх окон"){CheckOnClick=true};
 readonly ToolStripButton mini=new("Свернуть");
 readonly ToolStripStatusLabel status=new("Подключаем кассу…");
 readonly string dataRoot=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"IprintDesk");
 DeskSettings settings=new();Rectangle fullBounds;bool collapsed,closing,saving;bool hotkeyRegistered;
 public DeskForm(){
  Text=Program.Title;Font=new Font("Segoe UI",10);MinimumSize=new Size(440,105);StartPosition=FormStartPosition.Manual;
  Directory.CreateDirectory(dataRoot);try{settings=JsonSerializer.Deserialize<DeskSettings>(File.ReadAllText(Path.Combine(dataRoot,"window.json")))??new();}catch{}
  var area=Screen.PrimaryScreen!.WorkingArea;Bounds=new Rectangle(Math.Clamp(settings.X,area.Left,Math.Max(area.Left,area.Right-440)),Math.Clamp(settings.Y,area.Top,Math.Max(area.Top,area.Bottom-200)),Math.Min(Math.Max(settings.Width,440),area.Width),Math.Min(Math.Max(settings.Height,480),area.Height));fullBounds=Bounds;
  TopMost=pin.Checked=settings.Pinned;
  var sale=new ToolStripButton("Касса");sale.Click+=async(_,_)=>{RestoreDesk();await Script("window.DesktopPOS?.openSale()");};
  pin.Click+=(_,_)=>{TopMost=pin.Checked;SaveSettings();};mini.Click+=(_,_)=>ToggleMini();
  var menu=new ToolStripDropDownButton("Настройки");
  var startup=new ToolStripMenuItem("Запускать вместе с Windows"){CheckOnClick=true};
  using(var k=Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))startup.Checked=k?.GetValue("IprintDesk")!=null;
  startup.Click+=(_,_)=>{try{using var k=Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");if(startup.Checked)k.SetValue("IprintDesk","\""+Environment.ProcessPath+"\"");else k.DeleteValue("IprintDesk",false);}catch(Exception e){MessageBox.Show(e.Message,"Автозапуск");}};
  menu.DropDownItems.Add(startup);menu.DropDownItems.Add("Открыть обычный сайт",null,(_,_)=>External(Program.Site));
  menu.DropDownItems.Add("Перезагрузить кассу",null,async(_,_)=>{if(saving){MessageBox.Show("Дождитесь завершения оформления продажи.",Program.Title);return;}if(await Script("window.DesktopPOS?.beforeExit()")!="false")web.Reload();});
  menu.DropDownItems.Add("О программе",null,(_,_)=>MessageBox.Show("Айпринт · касса 0.1.0\nCtrl + Shift + I — показать или свернуть окно.\nДанные и вход сохраняются в профиле текущего пользователя Windows.\nДля оформления продажи нужен интернет.",Program.Title));
  strip.Items.AddRange([sale,mini,pin,menu]);
  var footer=new StatusStrip();footer.Items.Add(status);Controls.Add(web);Controls.Add(footer);Controls.Add(strip);
  Shown+=async(_,_)=>await InitializeWeb();FormClosing+=ClosingDesk;
 }
 protected override void OnHandleCreated(EventArgs e){base.OnHandleCreated(e);hotkeyRegistered=RegisterHotKey(Handle,1,0x4000|0x0002|0x0004,0x49);}
 protected override void OnHandleDestroyed(EventArgs e){if(hotkeyRegistered)UnregisterHotKey(Handle,1);base.OnHandleDestroyed(e);}
 protected override void WndProc(ref Message m){if(m.Msg==0x0312){if(collapsed||Form.ActiveForm!=this)RestoreDesk();else ToggleMini();}else if(m.Msg==0x8002)RestoreDesk();base.WndProc(ref m);}
 void RestoreDesk(){if(collapsed){collapsed=false;web.Visible=true;Bounds=fullBounds;mini.Text="Свернуть";}WindowState=FormWindowState.Normal;Show();Activate();}
 void ToggleMini(){if(collapsed){RestoreDesk();return;}if(WindowState!=FormWindowState.Normal)WindowState=FormWindowState.Normal;fullBounds=Bounds;collapsed=true;web.Visible=false;Height=108;mini.Text="Развернуть";SaveSettings();}
 void SaveSettings(){try{var b=collapsed?fullBounds:Bounds;File.WriteAllText(Path.Combine(dataRoot,"window.json"),JsonSerializer.Serialize(new DeskSettings(b.X,b.Y,b.Width,b.Height,pin.Checked)));}catch{}}
 static bool Allowed(string value){return Uri.TryCreate(value,UriKind.Absolute,out var u)&&u.Scheme=="https"&&u.Host=="iprintast-maker.github.io"&&u.AbsolutePath.StartsWith("/cloudshop/",StringComparison.Ordinal);}
 static void External(string url){if(Uri.TryCreate(url,UriKind.Absolute,out var u)&&(u.Scheme=="https"||u.Scheme=="http"))try{Process.Start(new ProcessStartInfo(url){UseShellExecute=true});}catch{}}
 async Task InitializeWeb(){
  try{
   var env=await CoreWebView2Environment.CreateAsync(null,Path.Combine(dataRoot,"WebProfile"));await web.EnsureCoreWebView2Async(env);
   web.CoreWebView2.Settings.AreDevToolsEnabled=false;web.CoreWebView2.Settings.IsStatusBarEnabled=false;web.CoreWebView2.Settings.AreDefaultContextMenusEnabled=false;web.CoreWebView2.Settings.IsPasswordAutosaveEnabled=false;
   web.CoreWebView2.NavigationStarting+=(_,e)=>{if(!Allowed(e.Uri)){e.Cancel=true;External(e.Uri);}};
   web.CoreWebView2.NewWindowRequested+=(_,e)=>{e.Handled=true;External(e.Uri);};
   web.CoreWebView2.WebMessageReceived+=(_,e)=>{if(!Allowed(e.Source))return;try{using var d=JsonDocument.Parse(e.WebMessageAsJson);var r=d.RootElement;if(r.GetProperty("type").GetString()!="desktop-state")return;status.Text=r.GetProperty("summary").GetString()??"Айпринт";saving=r.TryGetProperty("saving",out var s)&&s.GetBoolean();}catch{}};
   web.CoreWebView2.NavigationCompleted+=(_,e)=>{if(!e.IsSuccess)status.Text="Нет связи с сайтом. Проверьте интернет и нажмите «Настройки → Перезагрузить кассу».";};
   web.Source=new Uri(Program.Site+"?desktop=1");
  }catch(WebView2RuntimeNotFoundException){status.Text="Нужен Microsoft WebView2.";if(MessageBox.Show("Для кассы нужен бесплатный компонент Microsoft Edge WebView2. Запустите INSTALL.cmd из архива или установите компонент с сайта Microsoft. Открыть страницу Microsoft?",Program.Title,MessageBoxButtons.YesNo)==DialogResult.Yes)External("https://developer.microsoft.com/microsoft-edge/webview2/");}
  catch(Exception e){status.Text="Не удалось запустить кассу.";MessageBox.Show("Не удалось открыть кассу: "+e.Message,Program.Title);}
 }
 async Task<string?> Script(string script){try{return web.CoreWebView2==null?null:await web.CoreWebView2.ExecuteScriptAsync(script);}catch{return null;}}
 async void ClosingDesk(object? sender,FormClosingEventArgs e){
  if(closing)return;e.Cancel=true;if(saving){MessageBox.Show("Сейчас оформляется продажа. Дождитесь результата перед закрытием программы.",Program.Title);return;}
  var result=await Script("window.DesktopPOS?.beforeExit()");if(result=="false"&&MessageBox.Show("Черновик не удалось сохранить. Закрыть программу без сохранения?",Program.Title,MessageBoxButtons.YesNo)!=DialogResult.Yes)return;
  closing=true;SaveSettings();BeginInvoke(Close);
 }
 [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h,int id,uint modifiers,uint key);
 [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h,int id);
}
