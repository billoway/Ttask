"use strict";$(function(){FastClick.attach(document.body);var h5_yt={config:{y_loading:$("#loading"),y_pages:$(".page"),y_jt:$("#jt"),y_w:null,y_h:null,},init:function(){h5_yt.y_load();h5_yt.y_music();h5_yt.y_backgroundSize()},y_load:function(){console.log("2-load");var gaImgs=(function(){var taResult=[];var taResult=["images/page_lsw.png","images/page_lsw2.png","images/page1_bg.jpg","images/page1_bg2.png","images/page1_e1.png","images/page1_e2.png","images/page2_e1.png","images/page3_bg.jpg","images/page3_e1.png","images/page3_e2.png","images/page4_e1.png","images/page5_e1.png","images/page5_e2.png","images/page5_e3.png","images/page5_e4.png","images/page5_e5.png",];var taDOMIMG=document.getElementsByTagName("IMG");for(var i=0;i<taDOMIMG.length;i++){taResult.push(taDOMIMG[i].src)}return taResult})();setTimeout(function(){var loader=new PxLoader();for(var i=0;i<gaImgs.length;i++){var pxImg=new PxLoaderImage(gaImgs[i]);loader.add(pxImg)}loader.addProgressListener(function(e){var progress=e.completedCount/e.totalCount});loader.addCompletionListener(function(){h5_yt.config.y_loading.get(0).style.display="none";h5_yt.y_slider()});loader.start()},0)},y_backgroundSize:function(){console.log("3-size");h5_yt.config.y_w=document.body.clientWidth,h5_yt.config.y_h=document.body.clientHeight;var aPage=h5_yt.config.y_pages;for(var i=0;i<aPage.length;i++){aPage[i].style.backgroundSize=h5_yt.config.y_w+"px "+h5_yt.config.y_h+"px"}},y_slider:function(){console.log("5-slider");var myslider=new iSlider({wrap:".wrap",item:".page",index:0,lastLocate:false,onslide:function(index){if(index==7){h5_yt.config.y_jt.get(0).style.display="none"}else{h5_yt.config.y_jt.get(0).style.display="block"}}})},y_music:function(){var music=document.getElementById("music"),oMusic=document.getElementById("oMusic");var result=true;music.onclick=function(){if(result){oMusic.pause();music.style.backgroundPosition="0 0";result=false}else{oMusic.play();music.style.backgroundPosition="-30px 0";result=true}}},};h5_yt.init()});