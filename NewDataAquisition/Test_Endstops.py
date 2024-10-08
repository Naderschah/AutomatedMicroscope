import RPi.GPIO as GPIO
import json
import time

GPIO.setmode(GPIO.BCM)

with open('Pinout.json','r') as f: 
    gpio_pins = json.load(f)
print("This assumes motor direction and endstop pins align, test the motor direction first")
endstops = [i for x in gpio_pins["Endstops"] for i in x]

# Set up endstops -> Usually done by grid handler
for key in endstops:
    GPIO.setup(key, GPIO.IN, pull_up_down=GPIO.PUD_UP)
    time.sleep(0.001)

for i in range(len(gpio_pins["Endstops"])):

    print('Testing {}'.format({0:'x',1:'y',2:'z'}[i]))
    print('Press min')
    cond = True
    while cond:
        for q in range(len(endstops)):
            if GPIO.input(endstops[q]): 
                print('Pressed {} {}'.format({0:'x',1:'y',2:'z'}[q//2], ['min', 'max'][q%2]))
            if GPIO.input(gpio_pins['Endstops'][i][0]):
                print("Endstop correct")
                cond = False
                break
            else:
                pass
        time.sleep(1)
    
    print('Press max')
    cond = True
    while cond:
        for q in range(len(endstops)):
            if GPIO.input(endstops[q]): 
                print('Pressed {} {}'.format({0:'x',1:'y',2:'z'}[q//2], ['min', 'max'][q%2]))
            if GPIO.input(gpio_pins['Endstops'][i][1]):
                print("Endstop correct")
                cond=False
                break
            else:
                pass
        time.sleep(1)
    

    