# swinburne_tools
Tools specific to users associated with Swinburne University of Technology

# Connecting Nectar VM to ozstar
Go to https://desktop.rc.nectar.org.au/home/

Select 'Login VIA AAF (Australia)'

Select your organisation

Login (if necessary)

Select 'Neurodesktop' from the 'Desktop Library' (you may have to scroll down to see it)

Click '+Create Desktop'

Keep the 'Default zone' and click 'Create'

...wait....

Click 'Open Desktop'

If you get a pop-up window 'See txt and images copied to the clipboard', click 'Allow'.

Once the VM has started, click on the 'LXTerminal' icon at the bottom left corner of the browser window.

Run the following line in the terminal (use Ctrl-Shift-v to paste), and enter your ozstar username and password when prompted:

```
curl -Ls https://github.com/SwinburneNeuroimaging/swinburne_tools/raw/refs/heads/main/ozstar_setup.sh > /tmp/tmp.sh; bash /tmp/tmp.sh
```
