# swinburne_tools
Tools specific to users associated with Swinburne University of Technology

# Creating a Nectar VM and connecting to the Ozstar filesystem
Go to https://desktop.rc.nectar.org.au/home/

Select 'Login VIA AAF (Australia)' or 'Australia Access Federation'

Select your organisation

Login (if necessary)

Select 'Neurodesktop' from the 'Desktop Library' (you may have to scroll down to see it)

Click '+Create Desktop'

Keep the 'Default zone' and click 'Create'

...wait....

Click 'Open Desktop'

If you get a pop-up window 'See txt and images copied to the clipboard', click 'Allow'.

Once the VM has started, click on the 'LXTerminal' icon at the bottom left corner of the browser window.

![plot](./VM_terminal_screenshot.png)

Run the following line in the terminal (use Ctrl-Shift-v to paste), and enter your <ins>ozstar</ins> username and password when prompted:

```
curl -Ls https://raw.githubusercontent.com/SwinburneNeuroimaging/swinburne_tools/main/ozstar_setup.sh > /tmp/tmp.sh; bash /tmp/tmp.sh
```
This only has to be run once when the virtual machine is created. 

Sometimes the connection to the ozstar filesystem will be dropped (this will happen if the machine gets 'shelved' for instance). You can run the command 
```
reconnect_ozstar
```
in a terminal to reconnect to ozstar at any time.
